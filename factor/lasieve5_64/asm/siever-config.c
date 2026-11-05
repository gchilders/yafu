/*3:*/
#line 146 "siever-config.w"

static void
siever_init(void)
{
}

/*:3*//*5:*/
#line 159 "siever-config.w"

#ifndef MPQS_ONLY





const ulong schedule_primebounds[N_PRIMEBOUNDS]= 
{0x100000,0x200000,0x400000,0x800000,0x1000000,0x2000000,0x4000000,
0x8000000,0x10000000,0x20000000,0x40000000,0x80000000};

/* Sieve region per schedule, in bits, for each prime bound.  The values
   were chosen for x86 caches.  On Apple Silicon (arm64), regions 4 times as
   large are faster: fewer passes over each part of the factor base, at the
   cost of larger schedules.  Measured on an M3, single job:

     shift  I14 nfs512   I16 nfs631   I16 R942 (-c 100)
       0     18.0 s       53.5 s      165 s, 1.92 GB
       1     16.8 s       47.5 s      156 s, 2.25 GB
       2     16.2 s       44.0 s      151 s, 2.36 GB
       3     15.9 s       42.6 s      150 s, 2.57 GB
       5     15.6 s       41.7 s      149 s, 3.10 GB

   Peak memory on a large 16e SNFS job (degree 6, rlim 250M, alim 350M,
   lpb 36/35, q above the factor base limit), three jobs at once:

     shift  -a q=360M        -r q=260M
       0    0.88 GB, 306 s   1.00 GB, 296 s
       1    1.11 GB, 278 s   1.11 GB, 269 s
       2    1.29 GB, 264 s   1.29 GB, 255 s

   The default is 2 for 14e and 15e, which use little memory, and 1 for
   16e: about two thirds of the gain, so that more tasks fit on 8 GB Macs
   under BOINC's memory limits.  Build with -DSCHED_SIZEBITS_SHIFT=n to
   choose another. */
#ifndef SCHED_SIZEBITS_SHIFT
#if defined(__x86_64__)
#define SCHED_SIZEBITS_SHIFT 0
#elif I_bits >= 16
#define SCHED_SIZEBITS_SHIFT 1
#else
#define SCHED_SIZEBITS_SHIFT 2
#endif
#endif
#define SSB(x) ((x)+SCHED_SIZEBITS_SHIFT)
const ulong schedule_sizebits[N_PRIMEBOUNDS]= {SSB(20),SSB(21),SSB(22),SSB(23),SSB(24),SSB(25),SSB(26),SSB(27),SSB(28),SSB(29),SSB(30),32};
#endif/*:5*/
