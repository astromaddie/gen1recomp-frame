#include "VisibilitySelection.h"
namespace visibility {
Selection::Selection(const Bounds* g,size_t ng,const Range* r,size_t nr,const uint32_t* p,size_t np)
        :groups(g,g+ng),ranges(r,r+nr),indices(p,p+np) {
        size_t next=0;
        for (const auto& b:groups) {
            const double values[]={b.x0,b.y0,b.z0,b.x1,b.y1,b.z1};
            for(double v:values) if(!std::isfinite(v)) throw std::invalid_argument("nonfinite bounds");
            if(b.x0>b.x1||b.y0>b.y1||b.z0>b.z1) throw std::invalid_argument("inverted bounds");
        }
        for(const auto& v:ranges) {
            if(v.group>=ng||v.first!=next||v.count==0||v.count>np-next)
                throw std::invalid_argument("invalid ordered range");
            next+=v.count;
        }
        if(next!=np) throw std::invalid_argument("incomplete ordered ranges");
        masks[0].assign(ng,2);masks[1].assign(ng,2);
    }
bool Selection::visible(const Bounds& b,const View& v) {
        double x0=b.x0,x1=b.x1,y0=b.y0,y1=b.y1,z0=b.z0,z1=b.z1;
        if(!v.shadow) {
            x0=x0+v.ox-8;x1=x1+v.ox+8;z0=z0+v.oz-8;z1=z1+v.oz+8;
            y0=y0+v.oy-8;y1=y1+v.oy+8;
            if(v.k>0) {
                double fx=std::max(std::abs(x0-v.cx),std::abs(x1-v.cx));
                double fz=std::max(std::abs(z0-v.cz),std::abs(z1-v.cz));
                double nx=std::max(std::max(x0-v.cx,0.0),v.cx-x1);
                double nz=std::max(std::max(z0-v.cz,0.0),v.cz-z1);
                y0=y0-v.k*(fx*fx+fz*fz);y1=y1-v.k*(nx*nx+nz*nz);
            }
            x0-=v.pull;x1+=v.pull;y0-=v.pull;y1+=v.pull;z0-=v.pull;z1+=v.pull;
        }
        const int eyes=v.shadow?1:2,planes=v.shadow?6:4;
        for(int eye=0;eye<eyes;++eye) {
            bool outside=false;
            for(int i=0;i<planes;++i) {
                const auto& p=v.planes[eye*planes+i];
                double d=p[0]*(p[0]>=0?x1:x0)+p[1]*(p[1]>=0?y1:y0)+p[2]*(p[2]>=0?z1:z0)+p[3];
                if(d<(v.shadow?-0.0001:0.0)){outside=true;break;}
            }
            if(!outside)return true;
        }
        return false;
    }
Result Selection::select(const View& view,uint32_t* out) {
        const int which=view.shadow?1:0;auto& mask=masks[which];bool changed=false;
        for(size_t i=0;i<groups.size();++i) {
            const uint8_t keep=visible(groups[i],view);
            if(mask[i]!=keep){mask[i]=keep;changed=true;}
        }
        if(changed) {
            size_t n=0;
            for(const auto& r:ranges)if(mask[r.group])n+=r.count;
            counts[which]=n;
            if(n>0&&n<indices.size()) {
                size_t offset=0,first=0,count=0;
                auto flush=[&]() {
                    if(count)std::memcpy(out+offset,indices.data()+first,count*sizeof(uint32_t));
                    offset+=count;count=0;
                };
                // Adjacent retained groups form one original contiguous run.
                // Coalescing copies changes neither triangle order nor values.
                for(const auto& r:ranges) {
                    if(mask[r.group]) {if(!count)first=r.first;count+=r.count;}
                    else flush();
                }
                flush();
            }
        }
        return {counts[which],changed};
    }
}
