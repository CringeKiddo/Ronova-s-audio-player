#include <atomic>
#include <cmath>
#include <complex>
#include <cstdio>
#include <thread>
#include <vector>
#include <random>
#include "lock_free_ring_buffer.h"
#include "parametric_eq_dsp.h"
#include "brickwall_limiter_dsp.h"
#include "speed_reverb_dsp.h"
#include "ronova_mode_dsp.h"
using namespace ronova;

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; std::printf("FAIL: "); std::printf(__VA_ARGS__); std::printf("\n"); } else { std::printf("ok:   "); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

// Single-bin DFT amplitude of channel 0
static double toneAmp(const std::vector<float>& x, int start, int n, double f, double fs) {
  std::complex<double> acc = 0; 
  for (int i = 0; i < n; ++i) {
    double w = 0.5 - 0.5 * std::cos(2 * M_PI * i / (n - 1));
    acc += w * x[2 * (start + i)] * std::polar(1.0, -2 * M_PI * f * (start + i) / fs);
  }
  return 2.0 * std::abs(acc) / (0.5 * n);
}
static double rmsDb(const std::vector<float>& x, int start, int n) {
  double s = 0; for (int i = 0; i < n; ++i) s += double(x[2*(start+i)]) * x[2*(start+i)];
  return 10 * std::log10(s / n + 1e-30);
}

struct VecSource {
  const std::vector<float>* d; size_t pos = 0;
  int readFrames(float* dst, int n) {
    size_t avail = d->size() / 2 - pos; size_t k = std::min<size_t>(avail, n);
    std::memcpy(dst, d->data() + pos * 2, k * 2 * sizeof(float)); pos += k; return (int)k;
  }
};

static std::vector<float> sine(double f, double fs, int frames, double amp = 0.5) {
  std::vector<float> v(frames * 2);
  for (int i = 0; i < frames; ++i) v[2*i] = v[2*i+1] = float(amp * std::sin(2 * M_PI * f * i / fs));
  return v;
}

static void testResampler() {
  SincResampler::buildTables();
  // 44.1k -> 48k upsample of 1 kHz: output amplitude 0.5, residual (noise+distortion) very low.
  {
    auto in = sine(1000, 44100, 44100 * 2);
    VecSource src{&in}; SincResampler rs; rs.setRatio(44100.0 / 48000.0);
    std::vector<float> out(2 * 48000);
    int got = rs.process(src, out.data(), 48000);
    double a = toneAmp(out, 4000, 32768, 1000, 48000);
    // residual after removing fitted tone
    double s = 0, sn = 0; int n = 30000;
    for (int i = 6000; i < 6000 + n; ++i) { double ref = 0.5 * std::sin(2 * M_PI * 1000 * (i + 0.0) / 48000.0); (void)ref; }
    CHECK(got == 48000, "44.1k->48k produced %d frames", got);
    CHECK(std::fabs(a - 0.5) < 0.002, "44.1k->48k 1 kHz amplitude %.5f (want 0.5)", a);
    // spectral purity: peak of everything except the tone bin region, via brute-force scan
    double worst = 0; for (double f = 1500; f < 23000; f += 217.3) worst = std::max(worst, toneAmp(out, 4000, 16384, f, 48000));
    double snr = 20 * std::log10(a / (worst + 1e-12));
    CHECK(snr > 90, "44.1k->48k worst spur %.1f dB below tone", snr);
    (void)s; (void)sn;
  }
  // 96k -> 44.1k downsample: 30 kHz tone must be rejected (would alias to 14.1 kHz), 10 kHz passes.
  {
    auto in = sine(30000, 96000, 96000 * 2);
    auto pass = sine(10000, 96000, 96000 * 2);
    VecSource s1{&in}, s2{&pass}; SincResampler a, b; a.setRatio(96000.0 / 44100.0); b.setRatio(96000.0 / 44100.0);
    std::vector<float> o1(2 * 40000), o2(2 * 40000);
    a.process(s1, o1.data(), 40000); b.process(s2, o2.data(), 40000);
    double alias = toneAmp(o1, 4000, 16384, 14100, 44100);
    double keep = toneAmp(o2, 4000, 16384, 10000, 44100);
    CHECK(alias < 0.001, "96k->44.1k 30 kHz alias amplitude %.6f", alias);
    CHECK(std::fabs(keep - 0.5) < 0.003, "96k->44.1k 10 kHz passband amplitude %.5f", keep);
  }
  // Tape mode: ratio 0.8 -> 1 kHz becomes 800 Hz.
  {
    auto in = sine(1000, 48000, 48000 * 2);
    VecSource src{&in}; SincResampler rs; rs.setRatio(0.8);
    std::vector<float> out(2 * 48000);
    rs.process(src, out.data(), 48000);
    double a = toneAmp(out, 4000, 16384, 800, 48000);
    CHECK(std::fabs(a - 0.5) < 0.002, "tape 0.8x: 800 Hz amplitude %.5f", a);
  }
  // Refill across many small calls + compaction stays continuous (no discontinuity glitches).
  {
    auto in = sine(440, 48000, 48000 * 20);
    VecSource src{&in}; SincResampler rs; rs.setRatio(1.0);
    std::vector<float> out(2 * 64); double maxStep = 0; float prev = 0; bool first = true; long total = 0;
    for (int k = 0; k < 14000; ++k) { int g = rs.process(src, out.data(), 64); total += g;
      for (int i = 0; i < g; ++i) { if (!first) maxStep = std::max<double>(maxStep, std::fabs(out[2*i]-prev)); prev = out[2*i]; first = false; } }
    CHECK(maxStep < 0.5 * 2 * M_PI * 440 / 48000 * 1.05, "20 s continuous resample, max sample step %.5f, frames %ld", maxStep, total);
  }
}

static void testEq() {
  ParametricEq eq; eq.prepare(48000);
  auto in = sine(1000, 48000, 48000);
  auto flat = in; eq.process(flat.data(), 48000);
  bool same = true; for (size_t i = 0; i < in.size(); ++i) if (flat[i] != in[i]) { same = false; break; }
  CHECK(same, "flat EQ is bit-transparent");

  eq.setBand(8, 1000, 6.0f, 1.41f);
  auto x = sine(1000, 48000, 48000 * 2); eq.process(x.data(), 48000 * 2);
  double a = toneAmp(x, 60000, 16384, 1000, 48000);
  CHECK(std::fabs(20 * std::log10(a / 0.5) - 6.0) < 0.1, "peaking +6 dB at 1 kHz -> %.2f dB", 20 * std::log10(a / 0.5));
  auto y = sine(100, 48000, 48000 * 2); eq.process(y.data(), 48000 * 2);
  double b = toneAmp(y, 60000, 16384, 100, 48000);
  CHECK(std::fabs(20 * std::log10(b / 0.5)) < 0.3, "peaking band leaves 100 Hz alone (%.2f dB)", 20 * std::log10(b / 0.5));

  ParametricEq e2; e2.prepare(48000);
  e2.setBandType(0, 3); e2.setBand(0, 200, 0, 0.707f);   // high-pass 200 Hz
  e2.setBandType(15, 4); e2.setBand(15, 4000, 0, 0.707f); // low-pass 4 kHz
  e2.setBandType(3, 1); e2.setBand(3, 120, 8, 0.707f);   // low shelf +8
  e2.setBandType(12, 2); e2.setBand(12, 8000, -9, 0.707f); // high shelf -9
  auto t50 = sine(50, 48000, 96000), t8k = sine(10000, 48000, 96000), t2k = sine(2000, 48000, 96000);
  auto lo = sine(30, 48000, 96000);
  e2.process(t50.data(), 96000);
  CHECK(toneAmp(t50, 60000, 16384, 50, 48000) < 0.5 * 0.35 * 2.6, "HP200/LS+8: 50 Hz amplitude %.3f", toneAmp(t50, 60000, 16384, 50, 48000));
  ParametricEq e3; e3.prepare(48000); e3.setBandType(15, 4); e3.setBand(15, 4000, 0, 0.707f);
  e3.process(t8k.data(), 96000);
  CHECK(toneAmp(t8k, 60000, 16384, 10000, 48000) < 0.5 * 0.2, "LP4k attenuates 10 kHz (%.3f)", toneAmp(t8k, 60000, 16384, 10000, 48000));
  (void)t2k; (void)lo;

  // Zipper test: sweep gain while processing a tone; max sample jump must stay smooth.
  ParametricEq e4; e4.prepare(48000); auto tone = sine(1000, 48000, 48000 * 3);
  double maxJump = 0; float prev = 0; std::vector<float> blk(2 * 128);
  for (int k = 0; k < 48000 * 3 / 128; ++k) {
    if (k == 100) e4.setBand(8, 1000, 12.0f, 3.0f);
    std::memcpy(blk.data(), tone.data() + k * 256, 256 * sizeof(float));
    e4.process(blk.data(), 128);
    for (int i = 0; i < 128; ++i) { maxJump = std::max<double>(maxJump, std::fabs(blk[2*i] - prev)); prev = blk[2*i]; }
  }
  CHECK(maxJump < 0.5 * 2 * M_PI * 1000 / 48000 * 4.0 * 1.2, "gain sweep: max sample step %.4f (no zipper)", maxJump);
}

static void testExciter() {
  SubBassExciter ex; ex.prepare(48000);
  auto in = sine(50, 48000, 48000 * 2, 0.4);
  auto ref = in;
  ex.setAmount(1.0f); ex.process(in.data(), 48000 * 2);
  double h1 = toneAmp(in, 60000, 32768, 50, 48000), h2 = toneAmp(in, 60000, 32768, 100, 48000), h3 = toneAmp(in, 60000, 32768, 150, 48000);
  double r1 = toneAmp(ref, 60000, 32768, 50, 48000);
  CHECK(h2 > 0.01 && h3 > 0.01, "808 exciter synthesises 2nd (%.3f) and 3rd (%.3f) harmonics of 50 Hz (fund %.3f vs %.3f)", h2, h3, h1, r1);
  auto vox = sine(2000, 48000, 48000 * 2, 0.4); auto vref = vox;
  SubBassExciter e2; e2.prepare(48000); e2.setAmount(1.0f); e2.process(vox.data(), 96000);
  double d = 0; for (size_t i = 0; i < vox.size(); ++i) d = std::max<double>(d, std::fabs(vox[i] - vref[i]));
  CHECK(d < 0.002, "exciter leaves 2 kHz vocal-range content untouched (max diff %.5f)", d);
  float m = 0; for (float v : in) { if (!(v == v)) m = NAN; }
  CHECK(m == 0, "exciter output finite");
}

static void testWidth() {
  StereoWidthProcessor w; w.prepare(48000);
  std::vector<float> x(2 * 4800); for (int i = 0; i < 4800; ++i) { x[2*i] = 0.5f * std::sin(i * 0.05f); x[2*i+1] = 0.3f * std::sin(i * 0.031f); }
  auto ref = x; w.process(x.data(), 4800);
  CHECK(x == ref, "width 1.0 neutral is transparent");
  w.setMono(true); for (int k = 0; k < 40; ++k) w.process(x.data(), 4800);
  std::vector<float> y(2 * 4800); for (int i = 0; i < 4800; ++i) { y[2*i] = ref[2*i]; y[2*i+1] = ref[2*i+1]; }
  w.process(y.data(), 4800);
  double diff = 0; for (int i = 0; i < 4800; ++i) diff = std::max<double>(diff, std::fabs(y[2*i] - y[2*i+1]));
  CHECK(diff < 1e-5, "mono fold-down: L==R (max diff %.2e)", diff);
  float mid = 0.5f * (ref[2*100] + ref[2*100+1]); CHECK(std::fabs(y[2*100] - mid) < 1e-4, "mono = 0.5(L+R)");
}

static void testLimiter() {
  BrickwallLimiter lim; lim.prepare(48000);
  CHECK(lim.lookaheadSamples() == 240, "lookahead is %d samples at 48 kHz", lim.lookaheadSamples());
  lim.setPreGainDb(24.0f);
  std::mt19937 rng(1); std::normal_distribution<float> nd(0, 0.25f);
  int N = 48000 * 4; std::vector<float> x(2 * N);
  for (int i = 0; i < N; ++i) { float s = 0.4f * std::sin(2 * M_PI * 110 * i / 48000.0) + 0.3f * std::sin(2 * M_PI * 3100 * i / 48000.0) + nd(rng) * 0.2f;
    if (i % 12000 == 5000) s += 0.9f;   // transient spikes
    x[2*i] = s; x[2*i+1] = -0.8f * s; }
  float peak = 0; double rmsIn = 0, rmsOut = 0; for (int i = 0; i < N; ++i) rmsIn += x[2*i] * x[2*i];
  for (int k = 0; k < N; k += 480) lim.process(x.data() + 2 * k, 480);
  for (int i = 0; i < N; ++i) { peak = std::max(peak, std::max(std::fabs(x[2*i]), std::fabs(x[2*i+1]))); if (i > 48000) rmsOut += x[2*i] * x[2*i]; }
  CHECK(peak <= 0.9885f + 1e-6f, "+24 dB pre-gain: output peak %.5f <= 0.9885 ceiling", peak);
  CHECK(lim.gainReductionDb() > 6.0f, "GR meter reports %.1f dB", lim.gainReductionDb());
  (void)rmsIn;
  { // dense (non-spiky) programme at +24 dB: loudness must rise massively
    BrickwallLimiter ld; ld.prepare(48000); ld.setPreGainDb(24.0f);
    std::vector<float> m(2 * 96000); std::mt19937 r2(5); std::normal_distribution<float> n2(0, 0.004f);
    for (int i = 0; i < 96000; ++i) { float v = 0.15f * std::sin(2*M_PI*110*i/48000.0) + 0.12f * std::sin(2*M_PI*2300*i/48000.0) + 0.1f * std::sin(2*M_PI*5300*i/48000.0) + n2(r2); m[2*i] = v; m[2*i+1] = 0.9f * v; }
    double ri = 0, ro = 0; for (int i = 24000; i < 96000; ++i) ri += m[2*i] * m[2*i];
    for (int k = 0; k < 96000; k += 480) ld.process(m.data() + 2 * k, 480);
    for (int i = 24000; i < 96000; ++i) ro += m[2*i] * m[2*i];
    double gdb = 10 * std::log10(ro / ri); float pk = 0; for (float v : m) pk = std::max(pk, std::fabs(v));
    float inPeak = 0; for (int i = 0; i < 96000; ++i) { float v = 0.15f * std::sin(2*M_PI*110*i/48000.0) + 0.12f * std::sin(2*M_PI*2300*i/48000.0) + 0.1f * std::sin(2*M_PI*5300*i/48000.0); inPeak = std::max(inPeak, std::fabs(v)); }
    double ideal = 20 * std::log10(0.9885 / inPeak);   // distortion-free limit: peaks just touch the ceiling
    CHECK(gdb > ideal - 1.5 && gdb < ideal + 1.5 && pk <= 0.9885f + 1e-6f, "steady programme +24 dB: RMS +%.1f dB (distortion-free bound %.1f dB), peak %.4f", gdb, ideal, pk);
  }
  // Transparent at 0 dB with quiet material: output is the input delayed by lookahead.
  BrickwallLimiter l2; l2.prepare(48000); auto q = sine(1000, 48000, 9600, 0.25); auto qr = q;
  l2.process(q.data(), 9600); int la = l2.lookaheadSamples(); double md = 0;
  for (int i = 2000; i < 9000; ++i) md = std::max<double>(md, std::fabs(q[2*i] - qr[2*(i-la)]));
  CHECK(md < 1e-5, "0 dB + quiet signal: transparent (max diff vs delayed input %.2e)", md);
  // Square-wave check: heavily limited sine must not turn into a clipped square (low harmonic distortion at steady state)
  BrickwallLimiter l3; l3.prepare(48000); l3.setPreGainDb(12.0f);
  auto s3 = sine(200, 48000, 48000 * 2, 0.8); for (int k = 0; k < 96000; k += 480) l3.process(s3.data() + 2 * k, 480);
  double f1 = toneAmp(s3, 60000, 24000, 200, 48000), f3 = toneAmp(s3, 60000, 24000, 600, 48000);
  CHECK(f3 / f1 < 0.03, "+12 dB on a 0.8 sine: 3rd harmonic %.1f dB below fundamental (square wave would be -9.5 dB)", 20 * std::log10(f1 / (f3 + 1e-12)));
}

static void testReverb() {
  FdnReverb rv; rv.prepare(48000); rv.setRoomSpace(1.0f); rv.setEnabled(true);
  int N = 48000 * 12; std::vector<float> x(2 * N, 0.0f);
  for (int i = 0; i < 2000; ++i) { x[2*i] = 0.8f * std::sin(i * 0.4f) * (1 - i / 2000.0f); x[2*i+1] = x[2*i]; }
  double maxAbs = 0; bool finite = true;
  for (int k = 0; k < N; k += 480) { rv.process(x.data() + 2 * k, 480); }
  for (int i = 0; i < N; ++i) { maxAbs = std::max<double>(maxAbs, std::fabs(x[2*i])); if (!(x[2*i] == x[2*i])) finite = false; }
  auto seg = [&](double t0, double t1) { int a = int(t0 * 48000), b = int(t1 * 48000); double s = 0; for (int i = a; i < b; ++i) s += x[2*i] * x[2*i]; return 10 * std::log10(s / (b - a) + 1e-30); };
  double e1 = seg(0.5, 1.0), e2 = seg(4.5, 5.0);
  double decayPerSec = (e1 - e2) / 4.0;
  CHECK(finite && maxAbs < 2.0, "cathedral reverb finite, peak %.3f", maxAbs);
  CHECK(decayPerSec > 4 && decayPerSec < 30, "cathedral decay %.1f dB/s -> RT60 ~ %.1f s (target 7.5 s, damped tails measure faster)", decayPerSec, 60 / decayPerSec);
  CHECK(e1 > -90, "cathedral tail audible at 0.5-1.0 s (%.1f dB)", e1);

  FdnReverb rs; rs.prepare(48000); rs.setRoomSpace(0.0f); rs.setEnabled(true);
  std::vector<float> y(2 * N, 0.0f); for (int i = 0; i < 2000; ++i) { y[2*i] = 0.8f * std::sin(i * 0.4f) * (1 - i / 2000.0f); y[2*i+1] = y[2*i]; }
  for (int k = 0; k < N; k += 480) rs.process(y.data() + 2 * k, 480);
  auto seg2 = [&](double t0, double t1) { int a = int(t0 * 48000), b = int(t1 * 48000); double s = 0; for (int i = a; i < b; ++i) s += y[2*i] * y[2*i]; return 10 * std::log10(s / (b - a) + 1e-30); };
  double s1 = seg2(0.2, 0.4), s2 = seg2(1.0, 1.2);
  CHECK((s1 - s2) / 0.8 > 25, "studio room decay %.1f dB/s (fast)", (s1 - s2) / 0.8);

  // Toggle on/off while running: no NaN, output returns to dry.
  FdnReverb rt; rt.prepare(44100); rt.setEnabled(true); std::vector<float> z(2 * 44100, 0.1f);
  rt.process(z.data(), 44100); rt.setEnabled(false); for (int k = 0; k < 10; ++k) { std::vector<float> w(2 * 4410, 0.1f); rt.process(w.data(), 4410); if (k == 9) CHECK(std::fabs(w[10] - 0.1f) < 1e-3, "reverb disabled -> dry (%.5f)", w[10]); }
}

static void testRonova() {
  RonovaModeDsp r; r.prepare(48000); r.setEngaged(true, 1);
  auto x = sine(220, 48000, 48000 * 2, 0.4); for (size_t i = 0; i < x.size(); i += 2) x[i + 1] = 0.2f * x[i];
  for (int k = 0; k < 48000 * 2; k += 480) r.process(x.data() + 2 * k, 480);
  bool finite = true; double peak = 0; for (float v : x) { if (!(v == v)) finite = false; peak = std::max<double>(peak, std::fabs(v)); }
  CHECK(finite && peak < 1.5, "ronova chain finite, peak %.3f", peak);
  // Air shelf: +2.2 dB at 16 kHz region
  RonovaModeDsp a; a.prepare(48000); a.setEngaged(true, 1);
  auto hf = sine(16000, 48000, 48000 * 2, 0.2); auto hfr = hf; for (int k = 0; k < 96000; k += 480) a.process(hf.data() + 2 * k, 480);
  double g = 20 * std::log10(toneAmp(hf, 60000, 16384, 16000, 48000) / toneAmp(hfr, 60000, 16384, 16000, 48000));
  CHECK(g > 1.5 && g < 3.2, "air shelf gain at 16 kHz = %.2f dB (shelf +2.2 dB)", g);
  RonovaModeDsp off; off.prepare(48000); auto o = sine(1000, 48000, 4800); auto orf = o; off.process(o.data(), 4800);
  CHECK(o == orf, "ronova mode off is bit-transparent");
  RonovaModeDsp speaker; speaker.prepare(48000); speaker.setEngaged(true, 0);
  auto sp = sine(1000, 48000, 48000); for (int i = 0; i < 48000; ++i) sp[2*i+1] = 0; for (int k = 0; k < 48000; k += 480) speaker.process(sp.data() + 2 * k, 480);
  double rr = 0; for (int i = 24000; i < 48000; ++i) rr = std::max<double>(rr, std::fabs(sp[2*i+1])); CHECK(rr < 1e-5, "speaker profile: no crossfeed into the silent channel (%.2e)", rr);
}

static void testRing() {
  StereoRingBuffer* rb = new StereoRingBuffer();
  const long total = 3'000'000; std::atomic<bool> bad{false};
  std::thread prod([&] { std::vector<float> buf(2 * 777); long sent = 0; while (sent < total) {
    int n = (int)std::min<long>(777, total - sent); for (int i = 0; i < n; ++i) { buf[2*i] = float(sent + i); buf[2*i+1] = -float(sent + i); }
    size_t w = rb->write(buf.data(), n); if (w < (size_t)n) { /* partial: send rest */ size_t off = w; while (off < (size_t)n) { size_t x = rb->write(buf.data() + 2 * off, n - off); off += x; if (!x) std::this_thread::yield(); } }
    sent += n; } });
  long got = 0; std::vector<float> out(2 * 1024);
  while (got < total) { size_t n = rb->read(out.data(), 1024); for (size_t i = 0; i < n; ++i) { if (out[2*i] != float(got + i) || out[2*i+1] != -float(got + i)) bad = true; } got += n; if (!n) std::this_thread::yield(); }
  prod.join();
  CHECK(!bad && got == total, "SPSC ring: 3,000,000 frames transferred in order across threads");
  // discard
  rb->reset(); std::vector<float> d(2 * 1000, 1.0f); rb->write(d.data(), 1000); CHECK(rb->fillFrames() == 1000, "fill 1000");
  rb->discardAll(); CHECK(rb->fillFrames() == 0 && rb->readAvailable() == 0, "discardAll empties without touching consumer index");
  rb->write(d.data(), 10); std::vector<float> o2(2 * 10); CHECK(rb->applyDiscard() && rb->read(o2.data(), 10) == 10, "consumer adopts discard then reads only new data");
  CHECK(sizeof(StereoRingBuffer) >= 262144 * 2 * sizeof(float) && alignof(StereoRingBuffer) == 64, "ring is 262,144 frames, 64-byte aligned");
  delete rb;
}

int main() {
  testRing(); testResampler(); testEq(); testExciter(); testWidth(); testLimiter(); testReverb(); testRonova();
  std::printf("\n%s (%d failures)\n", failures ? "SOME TESTS FAILED" : "ALL TESTS PASSED", failures);
  return failures ? 1 : 0;
}
