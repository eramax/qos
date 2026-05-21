import http.server
import json
import os
import datetime
import sys
import platform
import socket
import subprocess
import urllib.request
import ssl
import threading
import time
from collections import deque

HISTORY_MAX   = 180   # 6 min at 2 s intervals
SAMPLE_INTERVAL = 2.0

SA_TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"
SA_CA    = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# ── helpers ──────────────────────────────────────────────────────────

def hbytes(b):
    for u in ["B","KB","MB","GB","TB"]:
        if b < 1024: return f"{b:.1f} {u}"
        b /= 1024
    return f"{b:.1f} PB"

def read_proc(p):
    try: return open(p).read().strip()
    except: return ""

def read_lines(p):
    try: return [l.strip() for l in open(p)]
    except: return []

def api(path):
    host = os.environ.get("KUBERNETES_SERVICE_HOST","kubernetes.default.svc")
    port = os.environ.get("KUBERNETES_SERVICE_PORT","443")
    url  = f"https://{host}:{port}{path}"
    for verify in [True, False]:
        try:
            tok = open(SA_TOKEN).read().strip()
            ctx = ssl.create_default_context(cafile=SA_CA) if verify else ssl._create_unverified_context()
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {tok}"})
            return json.loads(urllib.request.urlopen(req, context=ctx, timeout=5).read())
        except: pass
    return {}

# ── metrics collector ────────────────────────────────────────────────

class Collector:
    def __init__(self):
        self.history   = deque(maxlen=HISTORY_MAX)
        self._prev_net = {}
        self._prev_cpu = None
        self._prev_disk= {}
        self._lock     = threading.Lock()

    def _cpu_times(self):
        for line in read_lines("/proc/stat"):
            if line.startswith("cpu "):
                p = line.split()
                vals = [int(v) for v in p[1:]]
                total = sum(vals)
                return {"user":vals[0],"nice":vals[1],"system":vals[2],
                        "idle":vals[3],"iowait":vals[4] if len(vals)>4 else 0,"total":total}
        return None

    def _cpu_per_core(self):
        cores = []
        for line in read_lines("/proc/stat"):
            if line.startswith("cpu") and line[3].isdigit():
                p = line.split(); vals=[int(v) for v in p[1:]]
                total=sum(vals); idle=vals[3]
                cores.append({"id":p[0],"total":total,"idle":idle})
        return cores

    def _net_bytes(self):
        r={}
        for line in read_lines("/proc/net/dev")[2:]:
            p=line.split(); name=p[0].rstrip(":")
            if name=="lo": continue
            r[name]={"rx":int(p[1]),"tx":int(p[9])}
        return r

    def _disk_ios(self):
        r={}
        for line in read_lines("/proc/diskstats"):
            p=line.split(); name=p[2]
            if name.startswith("loop") or name.startswith("ram"): continue
            if len(p)>=14:
                r[name]={"reads":int(p[3]),"writes":int(p[7]),
                         "read_sectors":int(p[5]),"write_sectors":int(p[9])}
        return r

    def _tcp_count(self):
        count=0
        for path in ["/proc/net/tcp","/proc/net/tcp6"]:
            lines=read_lines(path)
            count += max(0,len(lines)-1)
        return count

    def _procs(self):
        r={"running":0,"blocked":0,"total":0}
        for line in read_lines("/proc/stat"):
            if line.startswith("procs_running"): r["running"]=int(line.split()[1])
            elif line.startswith("procs_blocked"): r["blocked"]=int(line.split()[1])
            elif line.startswith("processes"): r["total"]=int(line.split()[1])
        return r

    def _temps(self):
        zones={}
        import glob
        for path in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
            zone=path.split("/")[-2]
            try: zones[zone]=int(open(path).read().strip())/1000.0
            except: pass
        return zones

    def snapshot(self):
        now      = time.time()
        cpu      = self._cpu_times()
        net_now  = self._net_bytes()
        disk_now = self._disk_ios()
        load     = read_proc("/proc/loadavg").split()
        mem={}
        for line in read_lines("/proc/meminfo"):
            p=line.split()
            if len(p)>=2:
                k=p[0].rstrip(":").lower()
                v=int(p[1])*1024 if len(p)>2 and p[2]=="kB" else int(p[1])
                mem[k]=v

        # CPU delta
        cpu_pct={}
        if cpu and self._prev_cpu:
            d=cpu["total"]-self._prev_cpu["total"]
            if d>0:
                cpu_pct={k:(cpu[k]-self._prev_cpu[k])/d*100
                         for k in ["user","system","idle","iowait"]}
        self._prev_cpu=cpu

        # network delta (bytes/s)
        net_d={}
        for name,cur in net_now.items():
            prev=self._prev_net.get(name)
            if prev:
                net_d[name]={"rx":(cur["rx"]-prev["rx"])/SAMPLE_INTERVAL,
                             "tx":(cur["tx"]-prev["tx"])/SAMPLE_INTERVAL}
        self._prev_net=net_now

        # disk delta
        disk_d={}
        for name,cur in disk_now.items():
            prev=self._prev_disk.get(name)
            if prev:
                disk_d[name]={
                    "reads":  cur["reads"] -prev["reads"],
                    "writes": cur["writes"]-prev["writes"],
                    "rbytes": (cur["read_sectors"] -prev["read_sectors"])*512/SAMPLE_INTERVAL,
                    "wbytes": (cur["write_sectors"]-prev["write_sectors"])*512/SAMPLE_INTERVAL,
                }
        self._prev_disk=disk_now

        snap={
            "t":   now,
            "load":{"1m":float(load[0]),"5m":float(load[1]),"15m":float(load[2])} if len(load)>=3 else {},
            "cpu": cpu_pct,
            "mem": {k:mem.get(k,0) for k in ["memtotal","memfree","memavailable","cached","buffers","swaptotal","swapfree"]},
            "net": net_d,
            "disk":disk_d,
            "tcp": self._tcp_count(),
            "procs": self._procs(),
            "temps": self._temps(),
        }
        return snap

    def loop(self):
        while True:
            try:
                s=self.snapshot()
                with self._lock: self.history.append(s)
            except: pass
            time.sleep(SAMPLE_INTERVAL)

    def get(self):
        with self._lock: return list(self.history)

# ── static data ───────────────────────────────────────────────────────

def pod_info():
    return {"name":os.environ.get("POD_NAME",socket.gethostname()),
            "ip":os.environ.get("POD_IP",""),
            "namespace":os.environ.get("NAMESPACE","default"),
            "node":os.environ.get("NODE_NAME",""),
            "host_ip":os.environ.get("NODE_IP","")}

def cpu_info():
    info={}
    for line in read_lines("/proc/cpuinfo"):
        if ":" in line:
            k,v=line.split(":",1); k,v=k.strip(),v.strip()
            if k=="model name": info["model"]=v
            if k=="cpu cores": info["cores"]=v
            if k=="siblings": info["threads"]=v
            if k=="cpu MHz": info["mhz"]=v
    load=read_proc("/proc/loadavg").split()
    if len(load)>=5:
        info["load"]={"1m":load[0],"5m":load[1],"15m":load[2]}
        info["procs"]=load[3]
    up=float(read_proc("/proc/uptime").split()[0])
    d,h,m=int(up//86400),int((up%86400)//3600),int((up%3600)//60)
    info["uptime"]=f"{d}d {h}h {m}m"
    info["uptime_secs"]=up
    return info

def mem_info():
    raw={}
    for line in read_lines("/proc/meminfo"):
        p=line.split()
        if len(p)>=2:
            k=p[0].rstrip(":").lower()
            raw[k]=int(p[1])*1024 if len(p)>2 and p[2]=="kB" else int(p[1])
    r={}
    for k,lbl in [("memtotal","total"),("memfree","free"),("memavailable","available"),
                  ("cached","cached"),("buffers","buffers"),("swaptotal","swap_total"),("swapfree","swap_free")]:
        if k in raw: r[lbl]=raw[k]
    if "memtotal" in raw and "memavailable" in raw:
        used=raw["memtotal"]-raw["memavailable"]
        r["used"]=used
        r["used_pct"]=(used/raw["memtotal"])*100
        r["used_str"]=hbytes(used)
        r["total_str"]=hbytes(raw["memtotal"])
        r["available_str"]=hbytes(raw["memavailable"])
    return r

def disk_info():
    disks,seen=[],set()
    try:
        out=subprocess.check_output(["df","-B1"],text=True,timeout=3)
        for line in out.strip().split("\n")[1:]:
            p=line.split()
            if len(p)<6: continue
            fs,mnt=p[0],p[5]
            if fs in seen or fs in ("tmpfs","devtmpfs","shm","devpts","none","overlay") or fs.startswith("/")==False: continue
            if mnt in ("/dev","/sys","/proc","/run"): continue
            seen.add(fs)
            total,used,avail=int(p[1]),int(p[2]),int(p[3])
            pct=int(p[4].rstrip("%"))
            disks.append({"fs":fs,"mnt":mnt,"total":total,"used":used,"avail":avail,"pct":pct,
                          "total_str":hbytes(total),"used_str":hbytes(used),"avail_str":hbytes(avail)})
    except: pass
    return disks

def net_info():
    ifaces=[]
    for line in read_lines("/proc/net/dev")[2:]:
        p=line.split(); name=p[0].rstrip(":")
        if name=="lo": continue
        ifaces.append({"name":name,"rx_total":int(p[1]),"tx_total":int(p[9]),
                       "rx_str":hbytes(int(p[1])),"tx_str":hbytes(int(p[9]))})
    dns=""
    try:
        for line in open("/etc/resolv.conf"):
            if line.startswith("nameserver"): dns+=line.split()[1]+" "
    except: pass
    return {"interfaces":ifaces,"dns":dns.strip()}

def node_info():
    nm=os.environ.get("NODE_NAME","")
    if not nm: return {}
    n=api(f"/api/v1/nodes/{nm}")
    if not n: return {}
    md,st=n.get("metadata",{}),n.get("status",{})
    ni=st.get("nodeInfo",{})
    cap=st.get("capacity",{})
    alloc=st.get("allocatable",{})
    r={"name":md.get("name"),"arch":ni.get("architecture"),"kernel":ni.get("kernelVersion"),
       "os":ni.get("osImage"),"runtime":ni.get("containerRuntimeVersion"),
       "kubelet":ni.get("kubeletVersion"),"cpu_cap":cap.get("cpu"),
       "mem_cap":hbytes(int(cap.get("memory","0").rstrip("Ki"))*1024) if cap.get("memory","").endswith("Ki") else cap.get("memory"),
       "pods_cap":cap.get("pods"),
       "cpu_alloc":alloc.get("cpu"),"pods_alloc":alloc.get("pods")}
    for a in st.get("addresses",[]):
        if a["type"]=="Hostname": r["hostname"]=a["address"]
        if a["type"]=="InternalIP": r["internal_ip"]=a["address"]
        if a["type"]=="ExternalIP": r["external_ip"]=a["address"]
    r["conditions"]=[c["type"] for c in st.get("conditions",[]) if c.get("status")=="True"]
    lbls=md.get("labels",{})
    r["roles"]=[k.split("/")[1] for k in lbls if k.startswith("node-role.")]
    r["taints"]=[t.get("key") for t in n.get("spec",{}).get("taints",[])]
    # created
    created=md.get("creationTimestamp","")
    r["created"]=created
    return r

def cluster_info():
    ver=api("/version")
    nodes=api("/api/v1/nodes")
    node_list=[]
    for n in nodes.get("items",[]):
        md=n.get("metadata",{}); st=n.get("status",{})
        ready=any(c.get("type")=="Ready" and c.get("status")=="True" for c in st.get("conditions",[]))
        cap=st.get("capacity",{}); ni=st.get("nodeInfo",{})
        lbls=md.get("labels",{})
        roles=[k.split("/")[1] for k in lbls if k.startswith("node-role.")]
        node_list.append({"name":md.get("name"),"ready":ready,"roles":roles or ["worker"],
                          "cpu":cap.get("cpu"),"mem":cap.get("memory"),
                          "kubelet":ni.get("kubeletVersion"),"runtime":ni.get("containerRuntimeVersion"),
                          "os":ni.get("osImage")})
    return {"version":ver,"nodes":node_list}

# ── live k8s data (refreshed every poll) ─────────────────────────────

def live_pods():
    pods=api("/api/v1/pods")
    result=[]
    now=time.time()
    for p in pods.get("items",[]):
        md=p.get("metadata",{}); st=p.get("status",{}); spec=p.get("spec",{})
        phase=st.get("phase","Unknown")
        # compute ready
        cs=st.get("containerStatuses",[])
        ready_c=sum(1 for c in cs if c.get("ready"))
        total_c=len(cs) if cs else len(spec.get("containers",[]))
        restarts=sum(c.get("restartCount",0) for c in cs)
        # age
        created=md.get("creationTimestamp","")
        age_str=""
        try:
            from datetime import timezone
            t=datetime.datetime.fromisoformat(created.replace("Z","+00:00"))
            diff=datetime.datetime.now(timezone.utc)-t
            s=int(diff.total_seconds())
            if s<3600: age_str=f"{s//60}m"
            elif s<86400: age_str=f"{s//3600}h"
            else: age_str=f"{s//86400}d"
        except: age_str=created[:10]
        result.append({
            "ns":md.get("namespace",""),
            "name":md.get("name",""),
            "phase":phase,
            "ready":f"{ready_c}/{total_c}",
            "restarts":restarts,
            "age":age_str,
            "ip":st.get("podIP",""),
            "node":spec.get("nodeName",""),
        })
    result.sort(key=lambda x:(x["ns"],x["name"]))
    return result

def live_services():
    svcs=api("/api/v1/services")
    result=[]
    for s in svcs.get("items",[]):
        md=s.get("metadata",{}); sp=s.get("spec",{}); st=s.get("status",{})
        ports=",".join(f"{p.get('port')}/{p.get('protocol','TCP')}" for p in sp.get("ports",[]))
        ext=",".join(st.get("loadBalancer",{}).get("ingress",[{}])[0].get("ip","") for _ in [1]) or sp.get("externalIPs",[""])[0] or ""
        result.append({"ns":md.get("namespace",""),"name":md.get("name",""),
                       "type":sp.get("type",""),"cluster_ip":sp.get("clusterIP",""),
                       "external_ip":ext,"ports":ports})
    result.sort(key=lambda x:(x["ns"],x["name"]))
    return result

def live_ingresses():
    ing=api("/apis/networking.k8s.io/v1/ingresses")
    result=[]
    for i in ing.get("items",[]):
        md=i.get("metadata",{}); sp=i.get("spec",{})
        hosts=[r.get("host","") for r in sp.get("rules",[])]
        cls=sp.get("ingressClassName","")
        result.append({"ns":md.get("namespace",""),"name":md.get("name",""),
                       "class":cls,"hosts":", ".join(hosts)})
    result.sort(key=lambda x:(x["ns"],x["name"]))
    return result

def live_deployments():
    deps=api("/apis/apps/v1/deployments")
    result=[]
    for d in deps.get("items",[]):
        md=d.get("metadata",{}); st=d.get("status",{})
        result.append({"ns":md.get("namespace",""),"name":md.get("name",""),
                       "ready":f"{st.get('readyReplicas',0)}/{st.get('replicas',0)}",
                       "up_to_date":st.get("updatedReplicas",0),
                       "available":st.get("availableReplicas",0)})
    return result

# ── bootstrap static data ─────────────────────────────────────────────

POD     = pod_info()
CPU     = cpu_info()
MEM     = mem_info()
DISKS   = disk_info()
NET     = net_info()
NODE    = node_info()
CLUSTER = cluster_info()

COLL = Collector()
threading.Thread(target=COLL.loop, daemon=True).start()

# ── HTML / CSS ────────────────────────────────────────────────────────

CSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;background:#0d1117;color:#c9d1d9;padding:16px}
a{color:#58a6ff;text-decoration:none}
h1{color:#58a6ff;font-size:22px;margin-bottom:16px;display:flex;align-items:center;gap:10px}
h1 small{font-size:13px;color:#8b949e;font-weight:400}
h2{color:#58a6ff;font-size:14px;margin-bottom:10px;font-weight:600;letter-spacing:.3px}
.g2{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:12px}
.g3{display:grid;grid-template-columns:1fr 1fr 1fr;gap:12px;margin-bottom:12px}
.g4{display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:12px;margin-bottom:12px}
@media(max-width:1100px){.g3{grid-template-columns:1fr 1fr}.g4{grid-template-columns:1fr 1fr}}
@media(max-width:700px){.g2,.g3,.g4{grid-template-columns:1fr}}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px}
.card-full{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px;margin-bottom:12px}
.stat-big{text-align:center;padding:10px 6px}
.stat-big .val{font-size:28px;font-weight:700;color:#f0f6fc;line-height:1.1}
.stat-big .lbl{font-size:10px;color:#8b949e;text-transform:uppercase;letter-spacing:.8px;margin-top:3px}
.stat-big .sub{font-size:11px;color:#484f58;margin-top:2px}
table{width:100%;border-collapse:collapse;font-size:12px}
th{text-align:left;padding:5px 8px;color:#8b949e;font-weight:500;border-bottom:1px solid #21262d;white-space:nowrap}
td{padding:5px 8px;border-bottom:1px solid #161b22;font-family:"SFMono-Regular",Consolas,monospace;vertical-align:middle}
tr:hover td{background:#1c2129}
.kv th{width:150px;border-bottom:1px solid #21262d}
.kv td{border-bottom:1px solid #21262d}
.chart-box{height:160px;position:relative}
.badge{display:inline-block;padding:1px 7px;border-radius:9px;font-size:10px;font-weight:600}
.bg{background:#1b4123;color:#3fb950}
.by{background:#3d2e00;color:#d29922}
.br{background:#49241d;color:#f85149}
.bb{background:#0c2d6b;color:#58a6ff}
.bgr{background:#21262d;color:#8b949e}
.bar-wrap{background:#21262d;height:5px;border-radius:3px;overflow:hidden;min-width:60px}
.bar-fill{height:100%;border-radius:3px}
.section-label{font-size:11px;color:#484f58;text-transform:uppercase;letter-spacing:.8px;margin-bottom:8px;padding-bottom:4px;border-bottom:1px solid #21262d}
.iface-box{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:8px 12px;min-width:130px}
.footer{margin-top:16px;font-size:11px;color:#484f58;text-align:center;border-top:1px solid #21262d;padding-top:10px}
#clock{color:#8b949e;font-size:12px}
"""

def kv(rows):
    return '<table class="kv">'+"".join(
        f'<tr><th>{k}</th><td>{v}</td></tr>' for k,v in rows if v is not None and str(v).strip()
    )+"</table>"

def badge(text, cls="bgr"):
    return f'<span class="badge {cls}">{text}</span>'

def pct_bar(pct, color="#3fb950"):
    c = "#3fb950" if pct<70 else "#d29922" if pct<90 else "#f85149"
    return f'<div class="bar-wrap"><div class="bar-fill" style="width:{min(pct,100):.0f}%;background:{c}"></div></div>'

# ── page sections ─────────────────────────────────────────────────────

def section_topbar():
    used_pct = MEM.get("used_pct", 0)
    mem_used = MEM.get("used_str","?")
    mem_total= MEM.get("total_str","?")
    load1    = CPU.get("load",{}).get("1m","?")
    uptime   = CPU.get("uptime","?")
    ncores   = CPU.get("cores","?")
    pods_ready = sum(1 for n in CLUSTER.get("nodes",[]) if n.get("ready"))
    pods_total = len(CLUSTER.get("nodes",[]))

    disk_pct = DISKS[0]["pct"] if DISKS else 0
    disk_used= DISKS[0]["used_str"] if DISKS else "?"
    disk_total=DISKS[0]["total_str"] if DISKS else "?"

    return f"""
<div class="g4" style="margin-bottom:12px">
  <div class="card stat-big">
    <div class="val" id="top-cpu-pct">—%</div>
    <div class="lbl">CPU Usage</div>
    <div class="sub">{ncores} cores · load {load1}</div>
  </div>
  <div class="card stat-big">
    <div class="val">{used_pct:.0f}%</div>
    <div class="lbl">Memory Used</div>
    <div class="sub">{mem_used} / {mem_total}</div>
  </div>
  <div class="card stat-big">
    <div class="val">{disk_pct}%</div>
    <div class="lbl">Disk Used</div>
    <div class="sub">{disk_used} / {disk_total}</div>
  </div>
  <div class="card stat-big">
    <div class="val">{uptime}</div>
    <div class="lbl">Uptime</div>
    <div class="sub">nodes {pods_ready}/{pods_total} ready</div>
  </div>
</div>"""

def section_system():
    rows=[
        ("Model", CPU.get("model","")),
        ("Cores / Threads", f"{CPU.get('cores','?')} cores / {CPU.get('threads','?')} threads"),
        ("Uptime", CPU.get("uptime","")),
        ("Platform", platform.platform()),
        ("Python", sys.version.split()[0]),
        ("Memory Total", MEM.get("total_str","")),
        ("Memory Used", f"{MEM.get('used_str','')} ({MEM.get('used_pct',0):.1f}%)"),
        ("Memory Available", MEM.get("available_str","")),
        ("Swap Total", hbytes(MEM.get("swap_total",0))),
        ("Swap Free", hbytes(MEM.get("swap_free",0))),
    ]
    return kv(rows)

def section_pod():
    rows=[
        ("Pod Name", POD.get("name","")),
        ("Pod IP", POD.get("ip","")),
        ("Node", POD.get("node","")),
        ("Host IP", POD.get("host_ip","")),
        ("Namespace", POD.get("namespace","")),
    ]
    return kv(rows)

def section_node():
    conds=" ".join(badge(c,"bg") for c in NODE.get("conditions",[]))
    roles=" ".join(badge(r,"bb") for r in NODE.get("roles",[]))
    taints=" ".join(badge(t,"by") for t in NODE.get("taints",[])) or "none"
    rows=[
        ("Hostname", NODE.get("hostname","")),
        ("Internal IP", NODE.get("internal_ip","")),
        ("External IP", NODE.get("external_ip","")),
        ("Architecture", NODE.get("arch","")),
        ("OS", NODE.get("os","")),
        ("Kernel", NODE.get("kernel","")),
        ("Container Runtime", NODE.get("runtime","")),
        ("Kubelet Version", NODE.get("kubelet","")),
        ("CPU Capacity", NODE.get("cpu_cap","")),
        ("CPU Allocatable", NODE.get("cpu_alloc","")),
        ("Memory Capacity", NODE.get("mem_cap","")),
        ("Pod Capacity", NODE.get("pods_cap","")),
        ("Pod Allocatable", NODE.get("pods_alloc","")),
        ("Conditions", conds or "—"),
        ("Roles", roles or "—"),
        ("Taints", taints),
    ]
    return kv(rows)

def section_cluster():
    ver=CLUSTER.get("version",{})
    rows=[]
    if ver:
        rows+=[("K8s Version",ver.get("gitVersion","")),
               ("Go Version",ver.get("goVersion","")),
               ("Build Platform",ver.get("platform","")),
               ("Build Date",ver.get("buildDate","")[:10])]
    nodes=CLUSTER.get("nodes",[])
    rows.append(("Nodes", f"{len(nodes)} total, {sum(1 for n in nodes if n.get('ready'))} ready"))
    for n in nodes:
        s=badge("Ready","bg") if n.get("ready") else badge("NotReady","br")
        r=", ".join(n.get("roles",[]))
        mem=n.get("mem",""); mem_gb=""
        try: mem_gb=f" / {int(mem.rstrip('Ki'))*1024/1024/1024/1024:.1f}GB" if mem.endswith("Ki") else ""
        except: pass
        rows.append((n["name"], f'{s} &nbsp;CPU:{n.get("cpu","")} Mem{mem_gb} &nbsp;{r} &nbsp;<span style="color:#484f58">{n.get("kubelet","")}</span>'))
    return kv(rows)

def section_network():
    ifaces=NET.get("interfaces",[])
    html='<div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:10px">'
    for i in ifaces:
        html+=f'<div class="iface-box"><div style="font-size:11px;color:#58a6ff;margin-bottom:4px">{i["name"]}</div>'
        html+=f'<div style="font-size:12px">↓ {i["rx_str"]}</div><div style="font-size:12px">↑ {i["tx_str"]}</div></div>'
    html+="</div>"
    if NET.get("dns"):
        html+=f'<div style="font-size:11px;color:#8b949e">DNS: {NET["dns"]}</div>'
    return html

def section_disks():
    if not DISKS: return '<div style="color:#8b949e;font-size:12px">No data</div>'
    html=""
    for d in DISKS:
        html+=f'<div style="margin-bottom:10px">'
        html+=f'<div style="display:flex;justify-content:space-between;font-size:12px;margin-bottom:3px">'
        html+=f'<span style="color:#c9d1d9">{d["mnt"]}</span>'
        html+=f'<span style="color:#8b949e">{d["used_str"]} / {d["total_str"]} ({d["pct"]}%)</span></div>'
        html+=pct_bar(d["pct"])
        html+=f'<div style="font-size:10px;color:#484f58;margin-top:2px">{d["fs"]} &middot; {d["avail_str"]} free</div>'
        html+="</div>"
    return html

# ── JS (charts + live tables) ─────────────────────────────────────────

JS = r"""
const C={
  blue:'rgba(88,166,255,0.85)',  blueBg:'rgba(88,166,255,0.12)',
  green:'rgba(63,185,80,0.85)',  greenBg:'rgba(63,185,80,0.12)',
  red:'rgba(248,81,73,0.85)',
  orange:'rgba(247,160,71,0.85)',orangeBg:'rgba(247,160,71,0.12)',
  purple:'rgba(163,113,247,0.85)',purpleBg:'rgba(163,113,247,0.12)',
  yellow:'rgba(210,153,34,0.85)',yellowBg:'rgba(210,153,34,0.12)',
  cyan:'rgba(56,189,248,0.85)', cyanBg:'rgba(56,189,248,0.12)',
  gray:'rgba(139,148,158,0.5)',
};
const GRID='#21262d', TICK='#484f58';

function ts(t){
  const d=new Date(t*1000);
  return String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0')+':'+String(d.getSeconds()).padStart(2,'0');
}

function mkChart(id,datasets,opts={}){
  const ctx=document.getElementById(id);
  if(!ctx) return null;
  return new Chart(ctx,{
    type:'line',
    data:{labels:[],datasets},
    options:{
      responsive:true,maintainAspectRatio:false,
      animation:{duration:200},
      interaction:{mode:'index',intersect:false},
      plugins:{
        legend:{labels:{color:'#8b949e',boxWidth:10,padding:8,font:{size:10}}},
        tooltip:{bodyFont:{size:11},titleFont:{size:10}}
      },
      scales:{
        x:{ticks:{color:TICK,maxTicksLimit:6,font:{size:9}},grid:{color:GRID}},
        y:{ticks:{color:TICK,font:{size:9}},grid:{color:GRID},beginAtZero:true,...(opts.y||{})}
      },
      ...opts
    }
  });
}

function upd(ch,data,labels,series){
  if(!ch) return;
  ch.data.labels=labels;
  series.forEach((fn,i)=>{ ch.data.datasets[i].data=data.map(fn); });
  ch.update('none');
}

let charts={};

function initCharts(data){
  const lbl=data.map(d=>ts(d.t));

  charts.load=mkChart('cLoad',[
    {label:'1m', data:data.map(d=>d.load?.['1m']), borderColor:C.blue, backgroundColor:C.blueBg, fill:true, tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'5m', data:data.map(d=>d.load?.['5m']), borderColor:C.orange, backgroundColor:'transparent', borderDash:[4,3], tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'15m',data:data.map(d=>d.load?.['15m']),borderColor:C.gray, backgroundColor:'transparent', borderDash:[6,3], tension:.3, pointRadius:0, borderWidth:1.5},
  ],{y:{title:{display:true,text:'load',color:TICK,font:{size:9}}}});

  charts.cpuPct=mkChart('cCpuPct',[
    {label:'User',   data:data.map(d=>d.cpu?.user??null),   borderColor:C.blue,   backgroundColor:C.blueBg,   fill:true, tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'System', data:data.map(d=>d.cpu?.system??null), borderColor:C.red,    backgroundColor:'transparent', tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'IOWait', data:data.map(d=>d.cpu?.iowait??null), borderColor:C.yellow, backgroundColor:'transparent', tension:.3, pointRadius:0, borderWidth:1.5},
  ],{y:{max:100,title:{display:true,text:'%',color:TICK,font:{size:9}}}});

  const toGB=v=>+(v/1073741824).toFixed(3);
  charts.mem=mkChart('cMem',[
    {label:'Used',    data:data.map(d=>d.mem?toGB(d.mem.memtotal-d.mem.memavailable):null), borderColor:C.red,    backgroundColor:'transparent', tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'Cached',  data:data.map(d=>d.mem?toGB(d.mem.cached):null),                     borderColor:C.orange, backgroundColor:'transparent', tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'Buffers', data:data.map(d=>d.mem?toGB(d.mem.buffers):null),                    borderColor:C.yellow, backgroundColor:'transparent', tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'Free',    data:data.map(d=>d.mem?toGB(d.mem.memfree):null),                    borderColor:C.green,  backgroundColor:C.greenBg, fill:true, tension:.3, pointRadius:0, borderWidth:1.5},
  ],{y:{title:{display:true,text:'GB',color:TICK,font:{size:9}}}});

  charts.swap=mkChart('cSwap',[
    {label:'Swap Used', data:data.map(d=>d.mem?toGB((d.mem.swaptotal||0)-(d.mem.swapfree||0)):null), borderColor:C.purple, backgroundColor:C.purpleBg, fill:true, tension:.3, pointRadius:0, borderWidth:1.5},
    {label:'Swap Total',data:data.map(d=>d.mem?toGB(d.mem.swaptotal||0):null), borderColor:C.gray, backgroundColor:'transparent', borderDash:[4,3], tension:.3, pointRadius:0, borderWidth:1.5},
  ],{y:{title:{display:true,text:'GB',color:TICK,font:{size:9}}}});

  // net — all ifaces
  let netKeys=[];
  for(const d of data){if(d.net&&Object.keys(d.net).length){netKeys=Object.keys(d.net);break;}}
  const netDS=[];
  const netColors=[C.purple,C.orange,C.cyan,C.green];
  netKeys.forEach((k,i)=>{
    netDS.push({label:`${k} ↓`,data:data.map(d=>+(((d.net?.[k]?.rx??0)*8/1048576).toFixed(3))),borderColor:netColors[i*2%netColors.length],backgroundColor:'transparent',tension:.3,pointRadius:0,borderWidth:1.5});
    netDS.push({label:`${k} ↑`,data:data.map(d=>+(((d.net?.[k]?.tx??0)*8/1048576).toFixed(3))),borderColor:netColors[(i*2+1)%netColors.length],backgroundColor:'transparent',borderDash:[4,3],tension:.3,pointRadius:0,borderWidth:1.5});
  });
  charts.net=mkChart('cNet',netDS,{y:{title:{display:true,text:'Mbps',color:TICK,font:{size:9}}}});

  // disk — all devices
  let diskKeys=[];
  for(const d of data){if(d.disk&&Object.keys(d.disk).length){diskKeys=Object.keys(d.disk).slice(0,3);break;}}
  const diskDS=[];
  const diskColors=[C.cyan,C.orange,C.green];
  diskKeys.forEach((k,i)=>{
    diskDS.push({label:`${k} R`,data:data.map(d=>d.disk?.[k]?.reads??0),borderColor:diskColors[i],backgroundColor:'transparent',tension:.3,pointRadius:0,borderWidth:1.5});
    diskDS.push({label:`${k} W`,data:data.map(d=>d.disk?.[k]?.writes??0),borderColor:diskColors[i],backgroundColor:'transparent',borderDash:[4,3],tension:.3,pointRadius:0,borderWidth:1.5});
  });
  charts.disk=mkChart('cDisk',diskDS,{y:{title:{display:true,text:'IOPS',color:TICK,font:{size:9}}}});

  const diskBDS=[];
  diskKeys.forEach((k,i)=>{
    diskBDS.push({label:`${k} R`,data:data.map(d=>+(((d.disk?.[k]?.rbytes??0)/1048576).toFixed(3))),borderColor:diskColors[i],backgroundColor:'transparent',tension:.3,pointRadius:0,borderWidth:1.5});
    diskBDS.push({label:`${k} W`,data:data.map(d=>+(((d.disk?.[k]?.wbytes??0)/1048576).toFixed(3))),borderColor:diskColors[i],backgroundColor:'transparent',borderDash:[4,3],tension:.3,pointRadius:0,borderWidth:1.5});
  });
  charts.diskbytes=mkChart('cDiskBytes',diskBDS,{y:{title:{display:true,text:'MB/s',color:TICK,font:{size:9}}}});

  charts.tcp=mkChart('cTcp',[
    {label:'TCP Connections',data:data.map(d=>d.tcp??null),borderColor:C.cyan,backgroundColor:C.cyanBg,fill:true,tension:.3,pointRadius:0,borderWidth:1.5},
  ],{y:{title:{display:true,text:'conns',color:TICK,font:{size:9}}}});

  charts.procs=mkChart('cProcs',[
    {label:'Running',data:data.map(d=>d.procs?.running??null),borderColor:C.green,backgroundColor:C.greenBg,fill:true,tension:.3,pointRadius:0,borderWidth:1.5},
    {label:'Blocked',data:data.map(d=>d.procs?.blocked??null),borderColor:C.red,backgroundColor:'transparent',tension:.3,pointRadius:0,borderWidth:1.5},
  ],{y:{title:{display:true,text:'procs',color:TICK,font:{size:9}}}});

  charts._netKeys=netKeys;
  charts._diskKeys=diskKeys;
  charts.data=data;
  charts.labels=lbl;
}

function updateCharts(data){
  const lbl=data.map(d=>ts(d.t));

  upd(charts.load,data,lbl,[d=>d.load?.['1m'],d=>d.load?.['5m'],d=>d.load?.['15m']]);
  upd(charts.cpuPct,data,lbl,[d=>d.cpu?.user??null,d=>d.cpu?.system??null,d=>d.cpu?.iowait??null]);

  const toGB=v=>+(v/1073741824).toFixed(3);
  upd(charts.mem,data,lbl,[
    d=>d.mem?toGB(d.mem.memtotal-d.mem.memavailable):null,
    d=>d.mem?toGB(d.mem.cached):null,
    d=>d.mem?toGB(d.mem.buffers):null,
    d=>d.mem?toGB(d.mem.memfree):null,
  ]);
  upd(charts.swap,data,lbl,[
    d=>d.mem?toGB((d.mem.swaptotal||0)-(d.mem.swapfree||0)):null,
    d=>d.mem?toGB(d.mem.swaptotal||0):null,
  ]);

  // net
  if(charts.net){
    charts.net.data.labels=lbl;
    const nk=charts._netKeys;
    const ds=charts.net.data.datasets;
    nk.forEach((k,i)=>{
      ds[i*2].data=data.map(d=>+(((d.net?.[k]?.rx??0)*8/1048576).toFixed(3)));
      ds[i*2+1].data=data.map(d=>+(((d.net?.[k]?.tx??0)*8/1048576).toFixed(3)));
    });
    charts.net.update('none');
  }

  // disk
  if(charts.disk){
    charts.disk.data.labels=lbl;
    const dk=charts._diskKeys;
    const ds=charts.disk.data.datasets;
    dk.forEach((k,i)=>{ds[i*2].data=data.map(d=>d.disk?.[k]?.reads??0);ds[i*2+1].data=data.map(d=>d.disk?.[k]?.writes??0);});
    charts.disk.update('none');
  }
  if(charts.diskbytes){
    charts.diskbytes.data.labels=lbl;
    const dk=charts._diskKeys;
    const ds=charts.diskbytes.data.datasets;
    dk.forEach((k,i)=>{ds[i*2].data=data.map(d=>+(((d.disk?.[k]?.rbytes??0)/1048576).toFixed(3)));ds[i*2+1].data=data.map(d=>+(((d.disk?.[k]?.wbytes??0)/1048576).toFixed(3)));});
    charts.diskbytes.update('none');
  }

  upd(charts.tcp,data,lbl,[d=>d.tcp??null]);
  upd(charts.procs,data,lbl,[d=>d.procs?.running??null,d=>d.procs?.blocked??null]);

  // live top-cpu
  const last=data[data.length-1];
  if(last?.cpu?.user!=null){
    const tot=100-(last.cpu.idle??0);
    const el=document.getElementById('top-cpu-pct');
    if(el) el.textContent=tot.toFixed(1)+'%';
  }
}

// ── live tables ───────────────────────────────────────────────────────

function phaseClass(ph){
  if(ph==='Running') return 'bg';
  if(ph==='Pending') return 'by';
  if(ph==='Succeeded') return 'bb';
  return 'br';
}

function renderPods(pods){
  const tb=document.getElementById('pods-tbody');
  if(!tb||!pods) return;
  const byNs={};
  for(const p of pods){
    if(!byNs[p.ns]) byNs[p.ns]=[];
    byNs[p.ns].push(p);
  }
  let html='';
  for(const ns of Object.keys(byNs).sort()){
    html+=`<tr><td colspan="8" style="background:#0d1117;color:#8b949e;font-size:10px;text-transform:uppercase;letter-spacing:.8px;padding:6px 8px">${ns}</td></tr>`;
    for(const p of byNs[ns]){
      const rb=p.restarts>0?`<span class="badge ${p.restarts>5?'br':'by'}">${p.restarts}</span>`:p.restarts;
      html+=`<tr>
        <td style="color:#c9d1d9">${p.name}</td>
        <td><span class="badge ${phaseClass(p.phase)}">${p.phase}</span></td>
        <td>${p.ready}</td>
        <td>${rb}</td>
        <td>${p.age}</td>
        <td>${p.ip}</td>
        <td>${p.node}</td>
      </tr>`;
    }
  }
  tb.innerHTML=html;
  document.getElementById('pod-count').textContent=pods.length+' pods';
}

function renderServices(svcs){
  const tb=document.getElementById('svcs-tbody');
  if(!tb||!svcs) return;
  let html='';
  for(const s of svcs){
    const tc=s.type==='LoadBalancer'?'bb':s.type==='NodePort'?'by':'bgr';
    html+=`<tr>
      <td style="color:#8b949e;font-size:11px">${s.ns}</td>
      <td style="color:#c9d1d9">${s.name}</td>
      <td><span class="badge ${tc}">${s.type}</span></td>
      <td>${s.cluster_ip}</td>
      <td>${s.external_ip||'—'}</td>
      <td>${s.ports}</td>
    </tr>`;
  }
  tb.innerHTML=html;
}

function renderIngresses(ings){
  const tb=document.getElementById('ings-tbody');
  if(!tb||!ings) return;
  let html='';
  for(const i of ings){
    const hosts=i.hosts.split(',').map(h=>h.trim()).filter(Boolean);
    const hhtml=hosts.map(h=>`<a href="https://${h}" target="_blank" style="color:#58a6ff">${h}</a>`).join('<br>');
    html+=`<tr>
      <td style="color:#8b949e;font-size:11px">${i.ns}</td>
      <td style="color:#c9d1d9">${i.name}</td>
      <td><span class="badge bgr">${i.class}</span></td>
      <td>${hhtml||'—'}</td>
    </tr>`;
  }
  tb.innerHTML=html;
}

// ── poll loops ────────────────────────────────────────────────────────

async function pollHistory(){
  try{
    const r=await fetch('/history');
    const data=await r.json();
    if(data.length){
      if(Object.keys(charts).length===0) initCharts(data);
      else updateCharts(data);
    }
  }catch(e){}
  setTimeout(pollHistory,2000);
}

async function pollLive(){
  try{
    const [pr,sr,ir]=await Promise.all([
      fetch('/pods').then(r=>r.json()),
      fetch('/services').then(r=>r.json()),
      fetch('/ingresses').then(r=>r.json()),
    ]);
    renderPods(pr);
    renderServices(sr);
    renderIngresses(ir);
  }catch(e){}
  setTimeout(pollLive,8000);
}

function tickClock(){
  const el=document.getElementById('clock');
  if(el) el.textContent=new Date().toLocaleTimeString();
  setTimeout(tickClock,1000);
}

window.addEventListener('DOMContentLoaded',()=>{
  pollHistory();
  pollLive();
  tickClock();
});
"""

# ── page builder ──────────────────────────────────────────────────────

def build_page():
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>K3s Dashboard — {NODE.get('name','?')}</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.7/dist/chart.umd.min.js"></script>
<style>{CSS}</style>
</head>
<body>

<h1>
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#58a6ff" stroke-width="2"><circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/></svg>
  K3s Cluster Dashboard
  <small>{NODE.get('name','?')} &mdash; <span id="clock"></span></small>
</h1>

{section_topbar()}

<div class="g2">
  <div class="card"><h2>System</h2>{section_system()}</div>
  <div class="card"><h2>Pod (this container)</h2>{section_pod()}</div>
</div>

<div class="card-full"><h2>Node Details</h2>{section_node()}</div>
<div class="card-full"><h2>Cluster</h2>{section_cluster()}</div>

<div class="card-full">
  <h2>Pods &nbsp;<span id="pod-count" style="font-size:11px;color:#8b949e;font-weight:400"></span></h2>
  <table>
    <thead><tr><th>Name</th><th>Phase</th><th>Ready</th><th>Restarts</th><th>Age</th><th>Pod IP</th><th>Node</th></tr></thead>
    <tbody id="pods-tbody"><tr><td colspan="7" style="color:#484f58;padding:12px 8px">Loading…</td></tr></tbody>
  </table>
</div>

<div class="g2">
  <div class="card">
    <h2>Services</h2>
    <table>
      <thead><tr><th>NS</th><th>Name</th><th>Type</th><th>Cluster IP</th><th>External IP</th><th>Ports</th></tr></thead>
      <tbody id="svcs-tbody"><tr><td colspan="6" style="color:#484f58;padding:12px 8px">Loading…</td></tr></tbody>
    </table>
  </div>
  <div class="card">
    <h2>Ingresses</h2>
    <table>
      <thead><tr><th>NS</th><th>Name</th><th>Class</th><th>Hosts</th></tr></thead>
      <tbody id="ings-tbody"><tr><td colspan="4" style="color:#484f58;padding:12px 8px">Loading…</td></tr></tbody>
    </table>
  </div>
</div>

<div class="g2">
  <div class="card"><h2>Network Interfaces</h2>{section_network()}</div>
  <div class="card"><h2>Disks</h2>{section_disks()}</div>
</div>

<div class="section-label" style="margin-top:4px">Live Graphs — 6 minute window</div>

<div class="g2">
  <div class="card"><h2>CPU Load Average</h2><div class="chart-box"><canvas id="cLoad"></canvas></div></div>
  <div class="card"><h2>CPU Usage %</h2><div class="chart-box"><canvas id="cCpuPct"></canvas></div></div>
</div>

<div class="g2">
  <div class="card"><h2>Memory</h2><div class="chart-box"><canvas id="cMem"></canvas></div></div>
  <div class="card"><h2>Swap</h2><div class="chart-box"><canvas id="cSwap"></canvas></div></div>
</div>

<div class="g2">
  <div class="card"><h2>Network Throughput (Mbps)</h2><div class="chart-box"><canvas id="cNet"></canvas></div></div>
  <div class="card"><h2>Disk IOPS</h2><div class="chart-box"><canvas id="cDisk"></canvas></div></div>
</div>

<div class="g2">
  <div class="card"><h2>Disk Throughput (MB/s)</h2><div class="chart-box"><canvas id="cDiskBytes"></canvas></div></div>
  <div class="card"><h2>TCP Connections</h2><div class="chart-box"><canvas id="cTcp"></canvas></div></div>
</div>

<div class="g2">
  <div class="card"><h2>Processes</h2><div class="chart-box"><canvas id="cProcs"></canvas></div></div>
  <div class="card" style="display:flex;flex-direction:column;justify-content:center">
    <h2>Quick Links</h2>
    <div style="display:flex;flex-direction:column;gap:8px;font-size:13px">
      <a href="/json">/json — full snapshot as JSON</a>
      <a href="/history">/history — metrics history (JSON)</a>
      <a href="/pods">/pods — live pod list</a>
      <a href="/services">/services — live services</a>
      <a href="/ingresses">/ingresses — live ingresses</a>
      <a href="/healthz">/healthz — health check</a>
    </div>
  </div>
</div>

<div class="footer">
  K3s Cluster Dashboard &mdash; {NODE.get('os','')} &mdash; refreshes every 2s
</div>

<script>{JS}</script>
</body></html>"""

# ── page cache ────────────────────────────────────────────────────────

_page, _page_ts = None, 0

def get_page():
    global _page, _page_ts
    now=time.time()
    if not _page or now-_page_ts>30:
        _page=build_page(); _page_ts=now
    return _page

# ── HTTP handler ──────────────────────────────────────────────────────

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        routes={
            "/":        self._index,
            "/healthz": self._health,
            "/json":    self._json,
            "/history": self._history,
            "/pods":    self._pods,
            "/services":self._services,
            "/ingresses":self._ingresses,
        }
        routes.get(self.path, self._404)()

    def _send(self, body, ct="text/html; charset=utf-8", code=200):
        b=body if isinstance(body,bytes) else body.encode()
        self.send_response(code)
        self.send_header("Content-Type",ct)
        self.send_header("Access-Control-Allow-Origin","*")
        self.end_headers()
        self.wfile.write(b)

    def _index(self):    self._send(get_page())
    def _health(self):   self._send(json.dumps({"status":"ok","pod":POD.get("name")}),"application/json")
    def _history(self):  self._send(json.dumps(COLL.get(),default=str),"application/json")
    def _pods(self):     self._send(json.dumps(live_pods(),default=str),"application/json")
    def _services(self): self._send(json.dumps(live_services(),default=str),"application/json")
    def _ingresses(self):self._send(json.dumps(live_ingresses(),default=str),"application/json")
    def _404(self):      self._send("404 not found","text/plain",404)

    def _json(self):
        self._send(json.dumps({
            "pod":POD,"node":NODE,"cluster":CLUSTER,
            "system":{"cpu":CPU,"memory":MEM,"disks":DISKS,"network":NET},
            "latest":COLL.snapshot(),
        },default=str,indent=2),"application/json")

    def log_message(self,fmt,*a):
        sys.stderr.write(f"[{datetime.datetime.now().isoformat(timespec='seconds')}] {a[0]} {a[1]} {a[2]}\n")

http.server.HTTPServer(("0.0.0.0",80),H).serve_forever()
