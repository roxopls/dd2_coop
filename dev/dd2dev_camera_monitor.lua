-- Passive continuous camera monitor. No setters, gameplay hooks or script reset.
-- Latest 1200 frames plus 200 event candidates; output rewritten every two seconds.
if _G.dd2dev_camera_monitor then
    _G.dd2dev_camera_monitor.enabled = true
    return
end
local M = { enabled=true, frame=0, samples={}, events={}, sample_head=0,
    event_head=0, sample_count=0, event_count=0, marks=0, errors=0 }
_G.dd2dev_camera_monitor = M
local SAMPLE_MAX, EVENT_MAX = 1200, 200
local smtd = sdk.find_type_definition('via.SceneManager')
local function push_sample(v)
    M.sample_head=M.sample_head%SAMPLE_MAX+1
    M.samples[M.sample_head]=v
    M.sample_count=math.min(M.sample_count+1,SAMPLE_MAX)
end
local function event(kind, detail)
    M.event_head=M.event_head%EVENT_MAX+1
    M.events[M.event_head]={frame=M.frame,time=os.date('%Y-%m-%d %H:%M:%S'),kind=kind,detail=detail}
    M.event_count=math.min(M.event_count+1,EVENT_MAX)
end
local function ordered(items,head,count,max)
    local out={}
    for i=1,count do out[i]=items[(head-count+i-1)%max+1] end
    return out
end
local function flush()
    local ok,err=pcall(json.dump_file,'dd2dev_camera_monitor.json',{
        enabled=M.enabled,frame=M.frame,time=os.date('%Y-%m-%d %H:%M:%S'),
        errors=M.errors,last_error=M.last_error or '',marks=M.marks,
        samples=ordered(M.samples,M.sample_head,M.sample_count,SAMPLE_MAX),
        events=ordered(M.events,M.event_head,M.event_count,EVENT_MAX)
    })
    if not ok then M.last_error=tostring(err) end
end
local function capture()
    local sm=sdk.get_native_singleton('via.SceneManager')
    local view=sdk.call_native_func(sm,smtd,'get_MainView')
    local cam=view and view:call('get_PrimaryCamera')
    if not cam then return nil end
    local go=cam:call('get_GameObject')
    local xf=go:call('get_Transform')
    local p,q=xf:call('get_Position'),xf:call('get_Rotation')
    local s={frame=M.frame,time=os.time(),camera=string.format('%x',cam:get_address()),
        name=go:call('get_Name'),fov=cam:call('get_FOV'),
        x=p.x,y=p.y,z=p.z,qx=q.x,qy=q.y,qz=q.z,qw=q.w}
    local prev=M.prev
    if prev then
        s.jump=math.sqrt((s.x-prev.x)^2+(s.y-prev.y)^2+(s.z-prev.z)^2)
        s.fov_delta=s.fov-prev.fov
        if s.camera~=prev.camera then event('camera_changed',prev.camera..' -> '..s.camera) end
        if math.abs(s.fov_delta)>=2 then event('fov_step',string.format('%.3f -> %.3f',prev.fov,s.fov)) end
        if s.jump>=0.5 then event('position_step',string.format('%.3f m',s.jump)) end
    end
    M.prev=s
    return s
end
function M.mark()
    M.marks=M.marks+1
    event('USER_MARK','flicker '..M.marks)
    flush()
end
re.on_frame(function()
    M.frame=M.frame+1
    if not M.enabled then return end
    local ok,s=pcall(capture)
    if ok then
        if s then push_sample(s) else M.prev=nil end
    else
        M.errors=M.errors+1
        local err=tostring(s)
        if err~=M.last_error then event('error',err) end
        M.last_error=err
        M.prev=nil
    end
    local now=os.time()
    if not M.last_flush or now-M.last_flush>=2 then M.last_flush=now; flush() end
end)
re.on_draw_ui(function()
    if not imgui.tree_node('DD2 dev: monitor de camera') then return end
    local changed,value=imgui.checkbox('Monitorar camera',M.enabled)
    if changed then M.enabled=value; M.prev=nil; event(value and 'resumed' or 'paused','UI'); flush() end
    imgui.text('Quadros: '..M.frame..' | historico: '..M.sample_count..' | erros: '..M.errors)
    if M.prev then imgui.text(string.format('%s | FOV %.3f',M.prev.name,M.prev.fov)) end
    if imgui.button('Marcar flicada agora') then M.mark() end
    if imgui.button('Gravar historico agora') then flush() end
    if M.last_error then imgui.text(M.last_error) end
    imgui.tree_pop()
end)
event('started','passive per-frame capture; bounded history')
flush()
log.info('[dd2dev_camera_monitor] continuous passive monitor enabled')
