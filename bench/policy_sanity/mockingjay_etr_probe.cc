#include <cstdio>
#include <vector>
#include <numeric>
#include <algorithm>
static const int ETR_MAX=31, ETR_MIN=-32, NUM_WAY=16;
static int clamp_etr(int x){ return x>ETR_MAX?ETR_MAX:(x<ETR_MIN?ETR_MIN:x); }

// rdp_pred: the value the RDP hands back. 31 = cold/untrained.
void run(const char* label, int rdp_pred, int hit_pct){
  std::vector<int> etr(NUM_WAY, ETR_MAX);
  std::vector<bool> etr_valid(NUM_WAY,false), valid(NUM_WAY,false);
  long evictions=0, victim_is_last_touched=0, at_floor=0, samples=0;
  long last_touched = -1;
  const int N=20000; unsigned rng=12345;
  auto rnd=[&]{ rng=rng*1103515245u+12345u; return (rng>>16)&0x7fff; };

  for(int i=0;i<N;i++){
    bool hit=(rnd()%100)<hit_pct; long way;
    if(hit){ way=rnd()%NUM_WAY; if(!valid[way]) hit=false; }
    if(!hit){
      way=-1;
      for(long w=0;w<NUM_WAY;w++) if(!valid[w]){way=w;break;}
      if(way<0){
        long v=0; int mx=etr[0];
        for(long w=1;w<NUM_WAY;w++) if(etr[w]>mx){mx=etr[w];v=w;}
        way=v; evictions++;
        if(way==last_touched) victim_is_last_touched++;
        for(int w=0;w<NUM_WAY;w++) if(etr[w]==ETR_MIN) at_floor++;
        samples+=NUM_WAY;
      }
      valid[way]=true;
    }
    for(long w=0;w<NUM_WAY;w++) if(etr_valid[w]) etr[w]=clamp_etr(etr[w]-1);
    etr[way]=clamp_etr(rdp_pred);
    etr_valid[way]=true;
    last_touched=way;
  }
  printf("%-38s evictions=%6ld | victim==most-recently-touched: %5.1f%% | ways at ETR_MIN: %4.1f%%\n",
         label, evictions, 100.0*victim_is_last_touched/evictions, 100.0*at_floor/samples);
}
int main(){
  printf("Expected for a SANE policy: victim==most-recently-touched should be ~1/16 = 6.3%%\n\n");
  run("cold RDP (+31), 3%% hit (mcf-like)", 31, 3);
  run("cold RDP (+31), 20%% hit", 31, 20);
  run("trained RDP (+5 quanta), 3%% hit", 5, 3);
  run("trained RDP (+2 quanta), 20%% hit", 2, 20);
  run("trained RDP (-10, near reuse), 20%% hit", -10, 20);
  return 0;
}
