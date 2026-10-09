local path=assert(arg[1])
local time, reads, writes=0,0,{}
love={timer={getTime=function()return time end},graphics={
  isActive=function()return true end,isCreated=function()return true end}}
local output=io.stdout
io.stdout={write=function(_,line)writes[#writes+1]=line end,flush=function()end}
local runtime={status=function()
  reads=reads+1
  return {frame=3,frameOpen=false,bridge=true,shouldRender=false,
    lastError="test\nerror",native={sessionState="SYNCHRONIZED",focused=false,
      shouldRender=false,beginCount=3,submitCount=0}}
end}
local trace=assert(loadfile(path))()
trace.stage("unsampled",runtime);assert(reads==0)
trace.mark("boot-enter",runtime,"yellow")
assert(writes[1]:find("version=yellow",1,true))
trace.tick(runtime,"importer");trace.stage("draw-exit",runtime)
assert(reads==3 and writes[3]:find("submits=0",1,true))
assert(writes[3]:find("error=test error",1,true))
trace.tick(runtime,"game");trace.stage("not-sampled",runtime);assert(reads==3)
for i=1,179 do time=i;trace.tick(runtime,"game") end
local bounded=reads
time=1000;trace.tick(runtime,"game");trace.stage("bounded",runtime)
assert(reads==bounded,"periodic startup diagnostics must be bounded")
trace.mark("game-load-exit",runtime,"yellow");assert(reads==bounded+1)
trace.failure("lua\nerror"..string.rep("x",3000),runtime)
assert(writes[#writes]:find("lua_error=lua error",1,true) and #writes[#writes]<2600)
io.stdout=output
print("startup trace tests passed")
