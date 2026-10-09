#include "../VisibilitySelection.h"
#include <cassert>
#include <iostream>
using namespace visibility;
int main() {
 Bounds b[]={{0,0,0,1,1,1},{10,0,0,11,1,1},{20,0,0,21,1,1}};
 Range r[]={{0,3,0},{3,3,1},{6,3,2},{9,3,0},{12,3,2},{15,3,1}};
 uint32_t indices[]={9,7,2,4,5,6,3,2,1,0,1,2,2,3,4,1,3,5};
 Selection s(b,3,r,6,indices,18);uint32_t out[18];std::fill(out,out+18,999);
 View v;for(auto& p:v.planes)for(double& x:p)x=0;
 auto result=s.select(v,out);assert(result.changed&&result.count==18&&out[0]==999);
 result=s.select(v,out);assert(!result.changed&&result.count==18);
 // Every eye rejects group2; margin8 retained exactly at support-plane ties.
 v.planes[0][0]=-1;v.planes[0][3]=11;v.planes[4][0]=-1;v.planes[4][3]=11;
 result=s.select(v,out);assert(result.changed&&result.count==12);
 const uint32_t wanted[]={9,7,2,4,5,6,0,1,2,1,3,5};
 assert(std::memcmp(out,wanted,sizeof(wanted))==0);
 // Shadow masks are independent; exact threshold includes -0.0001.
 v.shadow=true;v.planes[0][3]=10-0.0001;
 result=s.select(v,out);assert(result.changed&&result.count==12);
 v.planes[0][3]=10-0.0001001;
 result=s.select(v,out);assert(result.changed&&result.count==6);
 v.shadow=false;v.planes[0][3]=11;
 result=s.select(v,out);assert(!result.changed&&result.count==12);
 bool failed=false;try{Range bad[]={{0,19,0}};Selection x(b,3,bad,1,indices,18);}catch(const std::invalid_argument&){failed=true;}
 assert(failed);
 failed=false;try{Bounds bad[]={{1,0,0,0,1,1}};Selection x(bad,1,r,6,indices,18);}catch(const std::invalid_argument&){failed=true;}
 assert(failed);
 std::cout<<"native visibility exact range/tie/cache validation passed\n";
}
