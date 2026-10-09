#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <stdexcept>
#include <vector>

// Packed immutable map selection. Keep IEEE double evaluation order identical
// to DrawDistance.lua; compile without floating-point contraction/fast-math.
namespace visibility {
struct Bounds { double x0,y0,z0,x1,y1,z1; };
struct Range { uint32_t first,count,group; };
struct View { double planes[8][4]; double ox=0,oy=0,oz=0,pull=0,k=0,cx=0,cz=0; bool shadow=false; };
struct Result { size_t count; bool changed; };
class Selection {
    std::vector<Bounds> groups;
    std::vector<Range> ranges;
    std::vector<uint32_t> indices;
    std::vector<uint8_t> masks[2];
    size_t counts[2]={0,0};
public:
    Selection(const Bounds* g,size_t ng,const Range* r,size_t nr,const uint32_t* p,size_t np);
    size_t size()const{return indices.size();}
    static bool visible(const Bounds& b,const View& v);
    Result select(const View& view,uint32_t* out);
};
}
