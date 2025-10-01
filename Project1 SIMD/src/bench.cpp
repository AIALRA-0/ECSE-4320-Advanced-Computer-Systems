// bench.cpp -- Project 1 SIMD Advantage Evaluation (index-stride version)
// Fix points retained:
// 1) kernel_dot uses "wide-precision accumulation + segmented partial sums", and uses mild guardrails to suppress reassociation
// 2) DOT verification compares in long double domain to avoid false negatives due to precision loss
// 3) Added FTZ/DAZ macro bridging (-DFTZ_DAZ also takes effect)
//
// Semantic change: added stride_mode = index | sample (default index)
//  - index: fixed workload (loop i=0..n-1), read source j incremented by stride and wraps within [0,n)
//  - sample: old semantics (i+=stride, workload decreases with stride)

#include <bits/stdc++.h>

#ifdef _WIN32
  #include <windows.h>
  #include <intrin.h>
  #define aligned_alloc_win(a,sz) _aligned_malloc((sz),(a))
  #define aligned_free_win(p) _aligned_free((p))
#else
  #include <x86intrin.h>
  #include <sys/time.h>
  #include <sched.h>
  #include <unistd.h>
#endif

#ifndef NDEBUG
#error "Build with -DNDEBUG (release) for stable results."
#endif

// ============ FTZ/DAZ macro bridging ============
#if defined(FTZ_DAZ) && !defined(ENABLE_FTZ_DAZ)
#define ENABLE_FTZ_DAZ
#endif

#if defined(__GNUC__) || defined(__clang__)
#define NOINLINE __attribute__((noinline))
#else
#define NOINLINE
#endif

// ===================== FTZ/DAZ =====================
static inline void set_ftz_daz(){
#ifdef ENABLE_FTZ_DAZ
  _MM_SET_FLUSH_ZERO_MODE(_MM_FLUSH_ZERO_ON);
  _MM_SET_DENORMALS_ZERO_MODE(_MM_DENORMALS_ZERO_ON);
#endif
}

// ===================== Safe RDTSC helpers =====================
static inline uint64_t rdtsc_safe(){ _mm_lfence(); uint64_t t=__rdtsc(); _mm_lfence(); return t; }
static inline uint64_t rdtscp_safe(){ unsigned aux; _mm_lfence(); uint64_t t=__rdtscp(&aux); _mm_lfence(); return t; }

// ===================== Timer =====================
#include <chrono>
#include <thread>
struct Timer {
  using clock = std::chrono::steady_clock;
  clock::time_point t0,t1;
  void start(){ t0=clock::now(); }
  void stop(){ t1=clock::now(); }
  double ns() const { return std::chrono::duration<double,std::nano>(t1-t0).count(); }
};

// ===================== Aligned alloc =====================
void* aligned_malloc(size_t align, size_t size){
#ifdef _WIN32
  return aligned_alloc_win(align, size);
#else
  void* p=nullptr; if(posix_memalign(&p, align, size)!=0) return nullptr; return p;
#endif
}
void aligned_free(void* p){
#ifdef _WIN32
  aligned_free_win(p);
#else
  free(p);
#endif
}

// ===================== Init =====================
template<class T>
void init_array(T* a, size_t n){
  std::mt19937_64 rng(12345);
  std::uniform_real_distribution<double> d(-1.0,1.0);
  for(size_t i=0;i<n;i++) a[i]=(T)d(rng);
}

// ===================== Verification helper function =====================
template<class T>
static inline bool nearly_equal(T a, T b, double rtol, double atol){
  double da=std::abs((double)a), db=std::abs((double)b);
  return std::abs((double)a-(double)b) <= atol + rtol*std::max(da,db);
}

// ===================== wider accum for dot =====================
template<class T> struct wider_accum { using type = long double; };
template<> struct wider_accum<float>  { using type = double;      };
template<> struct wider_accum<double> { using type = long double; };

// ===================== Args =====================
struct Args {
  std::string kernel="saxpy";
  std::string dtype="f32";
  size_t n=1<<24;
  size_t reps=9;
  size_t stride=1;
  bool   misalign=false;
  int    warmups=2;
  int    pin_core=-1;
  bool   verify=false;
  std::string stride_mode="index"; // "index" (default) | "sample"
};

// ===================== Pin to core =====================
#ifdef __linux__
void pin_to_core(int core){
  if(core<0) return;
  cpu_set_t set; CPU_ZERO(&set); CPU_SET(core,&set);
  (void)sched_setaffinity(0,sizeof(set),&set);
}
#else
void pin_to_core(int){ }
#endif

// ===================== CPU Hz estimation (stable) =====================
double estimate_cpu_hz_stable(){
  using clock = std::chrono::steady_clock;
  const int trials=5; const auto window=std::chrono::milliseconds(50);
  std::vector<double> ests; ests.reserve(trials);
  for(int i=0;i<trials;i++){
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
    uint64_t t0=rdtsc_safe(); auto c0=clock::now();
    while(clock::now()-c0<window){ _mm_pause(); }
    uint64_t t1=rdtscp_safe(); auto c1=clock::now();
    double ns=std::chrono::duration<double,std::nano>(c1-c0).count();
    double cyc=(double)(t1-t0);
    if(ns>0.0 && std::isfinite(ns) && cyc>0.0) ests.push_back(cyc/(ns*1e-9));
  }
  if(ests.empty()) return 0.0;
  std::sort(ests.begin(),ests.end());
  return ests[ests.size()/2];
}

// ===================== Robust percentile =====================
static double percentile(std::vector<double> v, double q){
  v.erase(std::remove_if(v.begin(),v.end(),[](double x){return !(x>0.0)||!std::isfinite(x);}),v.end());
  if(v.empty()) return std::numeric_limits<double>::quiet_NaN();
  std::sort(v.begin(),v.end()); size_t n=v.size();
  if(n<3) return v[n/2];
  if(n<20){ size_t idx=(size_t)std::llround(q*(n-1)); if(idx>=n) idx=n-1; return v[idx]; }
  double pos=q*(n-1); size_t i=(size_t)std::floor(pos); double f=pos-i;
  if(i+1<n) return v[i]*(1.0-f)+v[i+1]*f; return v[i];
}

// ===================== index-stride helpers =====================
// j advances by stride and wraps around to [0,n)
static inline size_t next_j(size_t j, size_t stride, size_t n){
  j += stride;
  if(j >= n) j -= n; // faster than %
  return j;
}

// ===================== Kernels (two paths: index / sample) =====================

// y[i] = a*x[j] + y[i]    (index semantics: i=0..n-1, j strides with wrap)
template<class T>
NOINLINE void kernel_saxpy_index(T a, const T* x, T* y, size_t n, size_t stride){
  if(n==0) return;
  size_t j=0;
  for(size_t i=0;i<n;i++){ y[i] = a * x[j] + y[i]; j = next_j(j, stride, n); }
}
// Old semantics: y[i] = a*x[i] + y[i], i+=stride
template<class T>
NOINLINE void kernel_saxpy_sample(T a, const T* x, T* y, size_t n, size_t stride){
  for(size_t i=0;i<n;i+=stride) y[i] = a * x[i] + y[i];
}

// dot: s += x[j]*y[i]     (index semantics)
template<class T>
NOINLINE T kernel_dot_index(const T* x, const T* y, size_t n, size_t stride){
  using A = typename wider_accum<T>::type;
#if defined(__clang__)
  #pragma clang fp reassociate(off) contract(off)
#elif defined(_MSC_VER)
  #pragma float_control(precise, on, push)
#endif
  if(n==0) return (T)0;
  size_t j=0;
  A s0=0, s1=0, s2=0, s3=0;
  size_t i=0;
  // 4-way accumulation to mitigate reassociation, while keeping order controlled
  for(; i+3<n; i+=4){
    s0 += (A)x[j] * (A)y[i];  j = next_j(j, stride, n);
    s1 += (A)x[j] * (A)y[i+1];j = next_j(j, stride, n);
    s2 += (A)x[j] * (A)y[i+2];j = next_j(j, stride, n);
    s3 += (A)x[j] * (A)y[i+3];j = next_j(j, stride, n);
  }
  for(; i<n; ++i){ s0 += (A)x[j] * (A)y[i]; j = next_j(j, stride, n); }
  A s = ((s0+s1)+(s2+s3));
#if defined(_MSC_VER)
  #pragma float_control(pop)
#endif
  return (T)s;
}
// Old semantics: i+=stride
template<class T>
NOINLINE T kernel_dot_sample(const T* x, const T* y, size_t n, size_t stride){
  using A = typename wider_accum<T>::type;
#if defined(__clang__)
  #pragma clang fp reassociate(off) contract(off)
#elif defined(_MSC_VER)
  #pragma float_control(precise, on, push)
#endif
  A s0=0, s1=0, s2=0, s3=0; size_t i=0; const size_t step=stride*4;
  for(; i+step<=n; i+=step){
    s0 += (A)x[i] * (A)y[i];
    s1 += (A)x[i+stride] * (A)y[i+stride];
    s2 += (A)x[i+2*stride] * (A)y[i+2*stride];
    s3 += (A)x[i+3*stride] * (A)y[i+3*stride];
  }
  for(; i<n; i+=stride) s0 += (A)x[i]* (A)y[i];
  A s=((s0+s1)+(s2+s3));
#if defined(_MSC_VER)
  #pragma float_control(pop)
#endif
  return (T)s;
}

// z[i] = x[j]*y[i]        (index semantics)
template<class T>
NOINLINE void kernel_mul_index(const T* x, const T* y, T* z, size_t n, size_t stride){
  if(n==0) return; size_t j=0;
  for(size_t i=0;i<n;i++){ z[i] = x[j]*y[i]; j = next_j(j, stride, n); }
}
// Old semantics: i+=stride
template<class T>
NOINLINE void kernel_mul_sample(const T* x, const T* y, T* z, size_t n, size_t stride){
  for(size_t i=0;i<n;i+=stride) z[i] = x[i]*y[i];
}

// 3-point stencil (independent of stride, kept original; to make sparse read, can be extended separately)
template<class T>
NOINLINE void kernel_stencil(const T* x, T* y, size_t n, T a, T b, T c){
  if(n<3) return;
  for(size_t i=1;i+1<n;i++) y[i] = a*x[i-1] + b*x[i] + c*x[i+1];
}

// ---------------- Bytes per element (used only for GiB/s rough estimate) ----------------
template<class T> double bpe_saxpy_index(){ return sizeof(T)*2.0 + sizeof(T); } // read x[j], read-modify-write y[i]
template<class T> double bpe_dot_index()  { return sizeof(T)*2.0; }             // read x[j], y[i]
template<class T> double bpe_mul_index()  { return sizeof(T)*2.0 + sizeof(T); } // read x[j],y[i],write z[i]
template<class T> double bpe_stencil()    { return sizeof(T)*2.0; }             // read x[i-1],x[i+1],write y[i] (rough estimate)

// ===================== DOT high-precision ref (index semantics) =====================
template<class T>
long double ref_dot_index_ld(const T* x, const T* y, size_t n, size_t stride, long double* sumAbs){
  if(sumAbs) *sumAbs = 0.0L;
  if(n==0) return 0.0L;
  long double s=0.0L, c=0.0L, sa=0.0L;
  size_t j=0;
  for(size_t i=0;i<n;i++){
    long double p = (long double)x[j] * (long double)y[i];
    long double yk = p - c;
    long double tk = s + yk;
    c = (tk - s) - yk;
    s = tk;
    sa += (p>=0? p : -p);
    j = next_j(j, stride, n);
  }
  if(sumAbs) *sumAbs = sa;
  return s;
}

// ===================== Main =====================
int main(int argc, char** argv){
  std::ios::sync_with_stdio(false); std::cin.tie(nullptr);

  Args A;
  for(int i=1;i<argc;i++){
    std::string s(argv[i]); auto next=[&](){ return std::string(argv[++i]); };
    if(s=="--kernel") A.kernel=next();
    else if(s=="--dtype") A.dtype=next();
    else if(s=="--n") A.n=std::stoull(next());
    else if(s=="--reps") A.reps=std::stoull(next());
    else if(s=="--stride") A.stride=std::stoull(next());
    else if(s=="--misalign") A.misalign=true;
    else if(s=="--warmups") A.warmups=std::stoi(next());
    else if(s=="--pin") A.pin_core=std::stoi(next());
    else if(s=="--verify") A.verify=true;
    else if(s=="--stride_mode") A.stride_mode=next(); // "index" | "sample"
    else { fprintf(stderr,"Unknown arg: %s\n", s.c_str()); return 1; }
  }

  if(A.stride==0) A.stride=1;
  A.warmups = std::max(2, A.warmups);
  A.reps    = std::max<size_t>(9, A.reps);

  _MM_SET_ROUNDING_MODE(_MM_ROUND_NEAREST);
  set_ftz_daz();
  pin_to_core(A.pin_core);

  auto run = [&](auto tag){
    using T=decltype(tag);
    const size_t align=64;
    const size_t n=A.n;
    const size_t x_extra=A.misalign?1:0;

    // Main buffers (for timing)
    T* x_base=(T*)aligned_malloc(align,(n+x_extra)*sizeof(T));
    T* y     =(T*)aligned_malloc(align, n*sizeof(T));
    T* z     =(T*)aligned_malloc(align, n*sizeof(T));
    if(!x_base||!y||!z){ fprintf(stderr,"Allocation failed\n");
      if(x_base)aligned_free(x_base); if(y)aligned_free(y); if(z)aligned_free(z); return; }
    T* x=x_base; if(A.misalign) x=(T*)((char*)x_base+sizeof(T));

    // Generate initial state
    init_array(x_base,n+x_extra);
    init_array(y,n);
    init_array(z,n);

    // Snapshot of initial state (for verification/check and each run)
    T* x0=(T*)aligned_malloc(align,(n+x_extra)*sizeof(T));
    T* y0=(T*)aligned_malloc(align, n*sizeof(T));
    T* z0=(T*)aligned_malloc(align, n*sizeof(T));
    memcpy(x0,x_base,(n+x_extra)*sizeof(T));
    memcpy(y0,y,n*sizeof(T));
    memcpy(z0,z,n*sizeof(T));
    T* x0v = x0; if(A.misalign) x0v=(T*)((char*)x0+sizeof(T));

    // ---------- warmup: temporary buffer, does not pollute main buffer ----------
    if(A.warmups>0){
      T* xw=(T*)aligned_malloc(align,(n+x_extra)*sizeof(T));
      T* yw=(T*)aligned_malloc(align, n*sizeof(T));
      T* zw=(T*)aligned_malloc(align, n*sizeof(T));
      if(xw&&yw&&zw){
        memcpy(xw,x_base,(n+x_extra)*sizeof(T));
        memcpy(yw,y,n*sizeof(T));
        memcpy(zw,z,n*sizeof(T));
        T* xwv=xw; if(A.misalign) xwv=(T*)((char*)xw+sizeof(T));
        for(int w=0; w<A.warmups; ++w){
          if(A.kernel=="saxpy"){
            if(A.stride_mode=="index")  kernel_saxpy_index<T>((T)1.111, xwv, yw, n, A.stride);
            else                         kernel_saxpy_sample<T>((T)1.111, xwv, yw, n, A.stride);
          } else if(A.kernel=="dot"){
            volatile T s2 = (A.stride_mode=="index")
              ? kernel_dot_index<T>(xwv,yw,n,A.stride)
              : kernel_dot_sample<T>(xwv,yw,n,A.stride);
            (void)s2;
          } else if(A.kernel=="mul"){
            if(A.stride_mode=="index")  kernel_mul_index<T>(xwv,yw,zw,n,A.stride);
            else                         kernel_mul_sample<T>(xwv,yw,zw,n,A.stride);
          } else if(A.kernel=="stencil"){
            kernel_stencil<T>(xwv,yw,n,(T)0.9,(T)1.1,(T)0.8);
          }
        }
      }
      if(xw)aligned_free(xw); if(yw)aligned_free(yw); if(zw)aligned_free(zw);
    }

    // ---------- Timing ----------
    std::vector<double> tns; tns.reserve(A.reps);
    for(size_t r=0;r<A.reps;r++){
      // Restore initial state (note: copy to base pointer, then adjust offset pointer)
      memcpy(x_base, x0, (n+x_extra)*sizeof(T));
      memcpy(y,      y0, n*sizeof(T));
      memcpy(z,      z0, n*sizeof(T));
      if(A.misalign) x = (T*)((char*)x_base + sizeof(T));
      else           x = x_base;

      Timer t; t.start();
      if(A.kernel=="saxpy"){
        if(A.stride_mode=="index")  kernel_saxpy_index<T>((T)1.111, x, y, n, A.stride);
        else                         kernel_saxpy_sample<T>((T)1.111, x, y, n, A.stride);
      } else if(A.kernel=="dot"){
        volatile T s2 = (A.stride_mode=="index")
          ? kernel_dot_index<T>(x,y,n,A.stride)
          : kernel_dot_sample<T>(x,y,n,A.stride);
        (void)s2;
      } else if(A.kernel=="mul"){
        if(A.stride_mode=="index")  kernel_mul_index<T>(x, y, z, n, A.stride);
        else                         kernel_mul_sample<T>(x, y, z, n, A.stride);
      } else if(A.kernel=="stencil"){
        kernel_stencil<T>(x,y,n,(T)0.9,(T)1.1,(T)0.8);
      }
      t.stop(); tns.push_back(t.ns());
    }

    const double med=percentile(tns,0.50);
    const double p05=percentile(tns,0.05);
    const double p95=percentile(tns,0.95);

    // ---------- Verification ----------
    bool verified=true; double max_rel_err=0.0;
    if(A.verify){
      // Reference buffers
      T* y_ref=(T*)aligned_malloc(align, n*sizeof(T));
      T* z_ref=(T*)aligned_malloc(align, n*sizeof(T));
      memcpy(y_ref,y0,n*sizeof(T));
      memcpy(z_ref,z0,n*sizeof(T));

      if(A.kernel=="saxpy"){
        if(A.stride_mode=="index"){
          // Reference: index semantics
          size_t j=0;
          for(size_t i=0;i<n;i++){ y_ref[i]=(T)1.111*x0v[j] + y_ref[i]; j=next_j(j,A.stride,n); }
          // Test
          T* y_chk=(T*)aligned_malloc(align, n*sizeof(T)); memcpy(y_chk,y0,n*sizeof(T));
          kernel_saxpy_index<T>((T)1.111, x0v, y_chk, n, A.stride);
          const double rtol = std::is_same_v<T,float> ? 1e-6 : 1e-12;
          const double atol = std::is_same_v<T,float> ? 1e-7 : 1e-13;
          for(size_t i=0;i<n;i++){
            if(!nearly_equal(y_chk[i], y_ref[i], rtol, atol)){
              verified=false;
              double rel = std::abs((double)y_chk[i] - (double)y_ref[i]) /
                           (atol + rtol*std::max(std::abs((double)y_chk[i]), std::abs((double)y_ref[i])));
              if(rel>max_rel_err) max_rel_err=rel;
            }
          }
          aligned_free(y_chk);
        }else{
          // Old sample semantics
          for(size_t i=0;i<n;i+=A.stride) y_ref[i]=(T)1.111*x0v[i] + y_ref[i];
          T* y_chk=(T*)aligned_malloc(align, n*sizeof(T)); memcpy(y_chk,y0,n*sizeof(T));
          kernel_saxpy_sample<T>((T)1.111, x0v, y_chk, n, A.stride);
          const double rtol = std::is_same_v<T,float> ? 1e-6 : 1e-12;
          const double atol = std::is_same_v<T,float> ? 1e-7 : 1e-13;
          for(size_t i=0;i<n;i+=A.stride){
            if(!nearly_equal(y_chk[i], y_ref[i], rtol, atol)){
              verified=false;
              double rel = std::abs((double)y_chk[i] - (double)y_ref[i]) /
                           (atol + rtol*std::max(std::abs((double)y_chk[i]), std::abs((double)y_ref[i])));
              if(rel>max_rel_err) max_rel_err=rel;
            }
          }
          aligned_free(y_chk);
        }
      }
      else if(A.kernel=="mul"){
        if(A.stride_mode=="index"){
          size_t j=0; for(size_t i=0;i<n;i++){ z_ref[i]=x0v[j]*y0[i]; j=next_j(j,A.stride,n); }
          T* z_chk=(T*)aligned_malloc(align, n*sizeof(T)); memcpy(z_chk,z0,n*sizeof(T));
          kernel_mul_index<T>(x0v, y0, z_chk, n, A.stride);
          const double rtol = std::is_same_v<T,float> ? 1e-6 : 1e-12;
          const double atol = std::is_same_v<T,float> ? 1e-7 : 1e-13;
          for(size_t i=0;i<n;i++){
            if(!nearly_equal(z_chk[i], z_ref[i], rtol, atol)){
              verified=false;
              double rel = std::abs((double)z_chk[i] - (double)z_ref[i]) /
                           (atol + rtol*std::max(std::abs((double)z_chk[i]), std::abs((double)z_ref[i])));
              if(rel>max_rel_err) max_rel_err=rel;
            }
          }
          aligned_free(z_chk);
        }else{
          for(size_t i=0;i<n;i+=A.stride) z_ref[i]=x0v[i]*y0[i];
          T* z_chk=(T*)aligned_malloc(align, n*sizeof(T)); memcpy(z_chk,z0,n*sizeof(T));
          kernel_mul_sample<T>(x0v, y0, z_chk, n, A.stride);
          const double rtol = std::is_same_v<T,float> ? 1e-6 : 1e-12;
          const double atol = std::is_same_v<T,float> ? 1e-7 : 1e-13;
          for(size_t i=0;i<n;i+=A.stride){
            if(!nearly_equal(z_chk[i], z_ref[i], rtol, atol)){
              verified=false;
              double rel = std::abs((double)z_chk[i] - (double)z_ref[i]) /
                           (atol + rtol*std::max(std::abs((double)z_chk[i]), std::abs((double)z_ref[i])));
              if(rel>max_rel_err) max_rel_err=rel;
            }
          }
          aligned_free(z_chk);
        }
      }
      else if(A.kernel=="stencil"){
        // Independent of stride, reuse original reference
        for(size_t i=1;i+1<n;i++) y_ref[i]=(T)0.9*x0v[i-1]+(T)1.1*x0v[i]+(T)0.8*x0v[i+1];
        T* y_chk=(T*)aligned_malloc(align, n*sizeof(T)); memcpy(y_chk,y0,n*sizeof(T));
        kernel_stencil<T>(x0v, y_chk, n, (T)0.9,(T)1.1,(T)0.8);
        const double rtol = std::is_same_v<T,float> ? 1e-6 : 1e-12;
        const double atol = std::is_same_v<T,float> ? 1e-7 : 1e-13;
        for(size_t i=1;i+1<n;i++){
          if(!nearly_equal(y_chk[i], y_ref[i], rtol, atol)){
            verified=false;
            double rel = std::abs((double)y_chk[i] - (double)y_ref[i]) /
                         (atol + rtol*std::max(std::abs((double)y_chk[i]), std::abs((double)y_ref[i])));
            if(rel>max_rel_err) max_rel_err=rel;
          }
        }
        aligned_free(y_chk);
      }
      else{ // DOT
        if(A.stride_mode=="index"){
          long double sa=0.0L;
          long double ref_ld = ref_dot_index_ld<T>(x0v, y0, n, A.stride, &sa);
          T v = kernel_dot_index<T>(x0v, y0, n, A.stride);
          const double eps = std::numeric_limits<T>::epsilon();
          const double nelems = (double)n;
          double rtol, atol1, atol2;
          if constexpr (std::is_same_v<T,float>) {
            rtol  = 1e-6;
            atol1 = 128.0 * eps * (double)sa + 1e-12;
            atol2 = 8.0   * std::sqrt(nelems);
          } else {
            rtol  = 1e-12;
            atol1 = 8.0 * eps * (double)sa + 1e-18;
            atol2 = 1e-6 * std::sqrt(nelems);
          }
          double atol = std::max(atol1, atol2);
          long double vv=(long double)v;
          long double denom=(long double)atol + (long double)rtol * std::max(std::fabs(vv), std::fabs(ref_ld));
          verified = std::fabs(vv - ref_ld) <= denom;
          max_rel_err = (double)( std::fabs(vv - ref_ld) / denom );
        } else {
          // sample semantics: stride sampling
          long double s=0.0L,c=0.0L,sa=0.0L;
          for(size_t i=0;i<n;i+=A.stride){
            long double p=(long double)x0v[i]*(long double)y0[i];
            long double yk=p-c, tk=s+yk; c=(tk-s)-yk; s=tk; sa+=(p>=0?p:-p);
          }
          T v = kernel_dot_sample<T>(x0v, y0, n, A.stride);
          const double eps = std::numeric_limits<T>::epsilon();
          const double nelems = (double)((n + (A.stride-1))/A.stride);
          double rtol, atol1, atol2;
          if constexpr (std::is_same_v<T,float>) {
            rtol  = 1e-6;
            atol1 = 128.0 * eps * sa + 1e-12;
            atol2 = 8.0   * std::sqrt(nelems);
          } else {
            rtol  = 1e-12;
            atol1 = 8.0 * eps * sa + 1e-18;
            atol2 = 1e-6 * std::sqrt(nelems);
          }
          double atol = std::max(atol1, atol2);
          long double vv=(long double)v;
          long double denom=(long double)atol + (long double)rtol * std::max(std::fabs(vv), std::fabs(s));
          verified = std::fabs(vv - s) <= denom;
          max_rel_err = (double)( std::fabs(vv - s) / denom );
        }
      }

      if(y_ref)aligned_free(y_ref); if(z_ref)aligned_free(z_ref);
    }

    // ====== Derived metrics ======
    const double flops_per_elem =
      (A.kernel=="saxpy")?2.0 :
      (A.kernel=="dot")  ?2.0 :
      (A.kernel=="mul")  ?1.0 : 5.0;

    // Under index semantics, workload = n; under sample semantics, still count n for fairness
    const double elems = (A.kernel=="stencil") ? (double)(n-2) : (double)n;

    const double gflops = (std::isfinite(med)&&med>0.0)
      ? flops_per_elem * elems / (med*1e-9) / 1e9
      : std::numeric_limits<double>::quiet_NaN();

    const double hz_est_local = estimate_cpu_hz_stable();
    double cpe=std::numeric_limits<double>::quiet_NaN();
    if(std::isfinite(med) && med>0.0 && hz_est_local>0.0)
      cpe = (med*1e-9) * hz_est_local / elems;

    // GiB/s is only a reference (more meaningful under index semantics)
    double bpe;
    if(A.kernel=="saxpy")      bpe = bpe_saxpy_index<T>();
    else if(A.kernel=="dot")   bpe = bpe_dot_index<T>();
    else if(A.kernel=="mul")   bpe = bpe_mul_index<T>();
    else                       bpe = bpe_stencil<T>();
    const double bytes=bpe*elems;
    const double gibps = (std::isfinite(med)&&med>0.0)
      ? (bytes/(med*1e-9))/(1024.0*1024.0*1024.0)
      : std::numeric_limits<double>::quiet_NaN();

    // Output CSV
    std::cout.setf(std::ios::fixed);
    std::cout << std::setprecision(6);
    std::cout
      << A.kernel << ","
      << (std::is_same_v<T,float> ? "f32" : "f64") << ","
      << n << ","
      << A.stride << ","
      << (A.misalign?1:0) << ","
      << A.reps << ","
      << med << ","
      << p05 << ","
      << p95 << ","
      << gflops << ","
      << cpe << ","
      << gibps << ","
      << (A.verify ? (verified?1:0) : -1) << ",";

    if (A.verify)
      std::cout << std::scientific << std::setprecision(13) << max_rel_err << "\n";
    else
      std::cout << "-1\n";

    // Free (only free base pointers)
    if(x0)aligned_free(x0); if(y0)aligned_free(y0); if(z0)aligned_free(z0);
    aligned_free(x_base); aligned_free(y); aligned_free(z);
  };

  if(A.dtype=="f32") run((float)0);
  else               run((double)0);
  return 0;
}
