param(
  [string]$DataPath = "viewer/map-data.json",
  [string]$OutDir = "viewer"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $DataPath)){
  throw "Data path not found: $DataPath. Run scripts/chunk-world.ps1 first."
}

# Progress activity label
$activity = 'Render viewer'
Write-Progress -Activity $activity -Status 'Loading data' -PercentComplete 5

# Load data to embed (file or shard directory)
if((Get-Item $DataPath).PSIsContainer){
  $metaPath = Join-Path $DataPath 'meta.json'
  if(-not (Test-Path -LiteralPath $metaPath)){
    throw "Shard directory missing meta.json: $DataPath"
  }
  $meta = Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
  $entities = New-Object System.Collections.ArrayList
  $shards = Get-ChildItem -LiteralPath $DataPath -Filter 'entities-*.json' -File | Sort-Object Name
  $i=0; $n = ($shards|Measure-Object).Count
  foreach($f in $shards){
    $i++
    Write-Progress -Activity $activity -Status ("Reading shard {0}/{1}: {2}" -f $i,$n,$f.Name) -PercentComplete ([int](10 + 50*($i/$n)))
    $arr = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
    foreach($e in $arr){ [void]$entities.Add($e) }
  }
  $out = [PSCustomObject]@{
    worldGuid=$meta.worldGuid
    grid=$meta.grid
    chunks=$meta.chunks
    entities=$entities
    templates=$meta.templates
    voxel=$meta.voxel
  }
} else {
  # Single-file JSON
  $out = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json
}
$entCount = ($out.entities | Measure-Object | % Count)
Write-Host ("Loaded data -> chunks: {0}, entities: {1}" -f ($out.chunks | Measure-Object | % Count), $entCount)
Write-Progress -Activity $activity -Status 'Preparing modules' -PercentComplete 20

if(-not (Test-Path -LiteralPath $OutDir)){ New-Item -ItemType Directory -Path $OutDir | Out-Null }

# Prepare inline ESM data URLs for three.js + OrbitControls to work from file:// without CORS
$threeDataUrl = $null
$orbitDataUrl = $null
try {
  $threeSrc = (Invoke-WebRequest -UseBasicParsing -Uri 'https://unpkg.com/three@0.158.0/build/three.module.js').Content
  $threeB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($threeSrc))
  $threeDataUrl = 'data:application/javascript;base64,' + $threeB64
  Write-Progress -Activity $activity -Status 'Fetched three.module.js' -PercentComplete 40

  $orbitSrc = (Invoke-WebRequest -UseBasicParsing -Uri 'https://unpkg.com/three@0.158.0/examples/jsm/controls/OrbitControls.js').Content
  $orbitFixed = $orbitSrc -replace "from 'three'","from '$threeDataUrl'"
  $orbitFixed = $orbitFixed -replace 'from "three"',("from '" + $threeDataUrl + "'")
  $orbitB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($orbitFixed))
  $orbitDataUrl = 'data:application/javascript;base64,' + $orbitB64
  Write-Progress -Activity $activity -Status 'Fetched OrbitControls' -PercentComplete 60
} catch {
  Write-Warning "Could not fetch ESM modules for inline usage: $_"
}

# HTML template copied from build-map.ps1 (kept in sync intentionally)
$html = @'
<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8" />
  <title>Enshrouded Map Preview</title>
  <style>
    html, body { margin:0; padding:0; height:100%; font: 14px/1.2 system-ui, sans-serif; }
    #bar { padding:8px; background:#111; color:#eee; position:fixed; top:0; left:0; right:0; z-index:3; display:flex; gap:12px; align-items:center; }
    #canvas { position:absolute; top:48px; left:0; right:0; bottom:0; background:#0b0f12; }
    #gl { position:absolute; top:48px; left:0; right:0; bottom:0; background:#060a0d; display:none; }
    #legend { margin-left:auto; opacity:0.8 }
    .badge { display:inline-block; padding:2px 6px; border-radius:10px; background:#333; }
    #panel { position:fixed; top:56px; right:10px; z-index:4; background:#111; color:#eee; border:1px solid #222; padding:8px; border-radius:6px; max-height:calc(100vh - 66px); overflow:hidden; min-width:200px; width:240px; resize: horizontal; }
    #panel h3 { margin:0 0 6px 0; font-size:14px; }
    #cats { display:block; max-height:calc(100vh - 130px); overflow:auto; padding-bottom:8px; }
    .chip { display:inline-block; width:14px; height:14px; border-radius:3px; margin-right:4px; vertical-align:middle; }
    .row { display:flex; gap:8px; align-items:center; margin-top:6px; }
    button { background:#222; color:#eee; border:1px solid #333; border-radius:4px; padding:2px 6px; cursor:pointer; font-size:12px; }
    button:hover { background:#2a2a2a; }
    #cats details { grid-column: 1 / span 2; border-bottom: 1px solid #1c1c1c; padding:4px 0; }
    #cats summary { list-style:none; cursor:pointer; display:flex; align-items:center; justify-content:space-between; }
    #cats summary::-webkit-details-marker { display:none; }
  </style>
  <script>
    // Shim since we use inline data below as <script type="module"> to load three
  </script>
  <!-- Inline ESM bootstrapping via data: URLs to avoid file:// CORS -->
  <script type="module">
    const threeUrl = '__THREE_DATAURL__';
    const orbitUrl = '__ORBIT_DATAURL__';
    try {
      const THREE = await import(threeUrl);
      const { OrbitControls } = await import(orbitUrl);
      window.THREE = THREE;
      window.OrbitControls = OrbitControls;
      window.__threeReady = true;
    } catch (e) {
      console.error('Failed to init Three via data URLs', e);
    }
  </script>
</head>
<body>
  <div id="bar">
    <div>World: <span id="world"></span></div>
    <div>Grid: <span id="grid"></span></div>
    <div>Chunks: <span id="chunks"></span></div>
    <div>Entities (shown): <span id="ents"></span></div>
    <div id="legend">
      <span class="badge" style="background:#2a7">chunk grid</span>
      <span class="badge" style="background:#e55">entity marker</span>
    </div>
  </div>
  <canvas id="canvas"></canvas>
  <div id="gl"></div>
  <div id="panel">
    <h3>View</h3>
    <div class="row">
      <label><input type="checkbox" id="mode3d" /> 3D-Modus</label>
      <label><input type="checkbox" id="showGrid" checked /> Grid</label>
      <label><input type="checkbox" id="showCoverage" /> Coverage</label>
      <label><input type="checkbox" id="showTerrain" /> Terrain</label>
      <span id="terrainOpts" style="display:none; gap:6px; align-items:center;">
        <label>Terrain color
          <select id="terrainColor">
            <option value="flat">flat</option>
            <option value="height">height</option>
          </select>
        </label>
        <label>Smooth <input id="terrainSmooth" type="range" min="0" max="4" step="1" value="1" style="width:90px"/></label>
        <label>Percentile <input id="terrainPct" type="range" min="10" max="90" step="5" value="75" style="width:110px"/> <span id="terrainPctVal" style="opacity:.8">75%</span></label>
        <label>Opacity <input id="terrainOpacity" type="range" min="0" max="1" step="0.05" value="0.85" style="width:110px"/></label>
      </span>
    </div>
    <div class="row">
      <label>Point size <input id="ptSize" type="range" min="0.5" max="8" step="0.5" value="3" /></label>
    </div>
    <div class="row" style="margin-top:8px">
      <button id="allOn">All</button>
      <button id="allOff">None</button>
      <span style="margin-left:auto">Color by <select id="colorMode"><option value="sub">subcategory</option><option value="group">group</option><option value="gray">grayscale</option><option value="mono">monochrome</option></select> <input type="color" id="monoColor" value="#d4ff66" title="Monochrome color" style="margin-left:6px; display:none; width:22px; height:22px; padding:0; border:none; background:transparent;" /></span>
    </div>
    <div id="cats"></div>
  </div>
  <script id="map-data" type="application/json">__JSON__</script>
  <script>
    const MAP_DATA = JSON.parse(document.getElementById('map-data').textContent);
    const canvas = document.getElementById('canvas');
    const ctx = canvas.getContext('2d');
    const glContainer = document.getElementById('gl');
    const barH = 48;
    const TERRAIN_WIDTH = 100;
    const TERRAIN_DEPTH = 100;
    const TERRAIN_HEIGHT = 50;
    function resize(){
      canvas.width = window.innerWidth; canvas.height = window.innerHeight - barH;
      if(renderer){ renderer.setSize(glContainer.clientWidth, glContainer.clientHeight, false); if(camera){ camera.aspect = glContainer.clientWidth/Math.max(1,glContainer.clientHeight); camera.updateProjectionMatrix(); } }
      renderAll();
    }
    window.addEventListener('resize', resize);

    // Build template name map (guid->name)
    const nameMap = new Map();
    const templateList = Array.isArray(MAP_DATA.templates) ? MAP_DATA.templates : [];
    for(const t of templateList) if(t && t.guid) nameMap.set(t.guid, t.name||null);
    // Attach names and categories (group + sub)
    const entsAll = (MAP_DATA.entities||[]).map(e=>{
      const name = e.templateName || nameMap.get(e.templateGuid) || 'unknown';
      const catGroup = categorize(name);
      const catSub = name;
      return { ...e, name, catGroup, catSub };
    });

    // Global Y bounds and linear fit between tile indices and world coordinates (precise alignment)
    const WORLD = { minX:Infinity, maxX:-Infinity, minY:Infinity, maxY:-Infinity, minZ:Infinity, maxZ:-Infinity };
    const statsX = { count:0, sumT:0, sumW:0, sumTT:0, sumTW:0 };
    const statsZ = { count:0, sumT:0, sumW:0, sumTT:0, sumTW:0 };
    for(const e of entsAll){
      if(Number.isFinite(e.x)){
        if(e.x < WORLD.minX) WORLD.minX = e.x;
        if(e.x > WORLD.maxX) WORLD.maxX = e.x;
        const t = e.tileX + 0.5;
        statsX.count++; statsX.sumT += t; statsX.sumW += e.x; statsX.sumTT += t*t; statsX.sumTW += t*e.x;
      }
      if(Number.isFinite(e.y)){
        if(e.y < WORLD.minY) WORLD.minY = e.y;
        if(e.y > WORLD.maxY) WORLD.maxY = e.y;
      }
      if(Number.isFinite(e.z)){
        if(e.z < WORLD.minZ) WORLD.minZ = e.z;
        if(e.z > WORLD.maxZ) WORLD.maxZ = e.z;
        const t = e.tileY + 0.5;
        statsZ.count++; statsZ.sumT += t; statsZ.sumW += e.z; statsZ.sumTT += t*t; statsZ.sumTW += t*e.z;
      }
    }
    if(!isFinite(WORLD.minX) || WORLD.minX===WORLD.maxX){ WORLD.minX = 0; WORLD.maxX = 1; }
    if(!isFinite(WORLD.minY) || WORLD.minY===WORLD.maxY){ WORLD.minY = 0; WORLD.maxY = 1; }
    if(!isFinite(WORLD.minZ) || WORLD.minZ===WORLD.maxZ){ WORLD.minZ = 0; WORLD.maxZ = 1; }

    const gxTiles = Math.max(1, MAP_DATA.grid.x);
    const gyTiles = Math.max(1, MAP_DATA.grid.y);
    const solveAxis = (stats, fallbackScale, fallbackOffset)=>{
      const denom = stats.count * stats.sumTT - stats.sumT * stats.sumT;
      let scale = fallbackScale;
      let offset = fallbackOffset;
      if(stats.count >= 2 && Math.abs(denom) > 1e-6){
        const s = (stats.count * stats.sumTW - stats.sumT * stats.sumW) / denom;
        if(Math.abs(s) > 1e-6){
          scale = s;
          offset = (stats.sumW - scale * stats.sumT) / stats.count;
        }
      }
      if(Math.abs(scale) < 1e-6){ scale = fallbackScale || 1; }
      return { scale, offset };
    };
    const fitX = solveAxis(statsX, (WORLD.maxX - WORLD.minX) / gxTiles || 1, Number.isFinite(WORLD.minX) ? WORLD.minX : 0);
    const fitZ = solveAxis(statsZ, (WORLD.maxZ - WORLD.minZ) / gyTiles || 1, Number.isFinite(WORLD.minZ) ? WORLD.minZ : 0);
    const invScaleX = Math.abs(fitX.scale) > 1e-6 ? 1/fitX.scale : null;
    const invScaleZ = Math.abs(fitZ.scale) > 1e-6 ? 1/fitZ.scale : null;
    const cellX = TERRAIN_WIDTH / gxTiles;
    const cellZ = TERRAIN_DEPTH / gyTiles;
    const tileCenterX = (e)=>{
      if(invScaleX !== null && Number.isFinite(e.x)) return ((e.x - fitX.offset) * invScaleX) - 0.5;
      return e.tileX;
    };
    const tileCenterZ = (e)=>{
      if(invScaleZ !== null && Number.isFinite(e.z)) return ((e.z - fitZ.offset) * invScaleZ) - 0.5;
      return e.tileY;
    };
    const sceneXFromTile = (tileFloat)=> (-TERRAIN_WIDTH/2) + cellX/2 + tileFloat * cellX;
    const sceneZFromTile = (tileFloat)=> (-TERRAIN_DEPTH/2) + cellZ/2 + tileFloat * cellZ;

    // Precompute coverage counts per tile (all entities, unabhängig von Filtern)
    const gxAll = MAP_DATA.grid.x, gyAll = MAP_DATA.grid.y;
    const coverageCounts = Array.from({length: gyAll},()=>Array.from({length: gxAll},()=>0));
    for(const e of entsAll){ if(e.tileX>=0&&e.tileX<gxAll&&e.tileY>=0&&e.tileY<gyAll){ coverageCounts[e.tileY][e.tileX]++; } }

    // Category palette
    const CAT_COLORS = new Map(Object.entries({
      loot:'#ff6b6b', spawner:'#ff4d6d', enemy:'#f94144', npc:'#ffd166', vfx:'#4cc9f0', map:'#4895ef', marker:'#4895ef',
      resource:'#80ed99', tree:'#57cc99', bush:'#64dfdf', rock:'#adb5bd', building:'#9d4edd', camp:'#ffafcc', chest:'#f77f00',
      teleporter:'#48cae4', trigger:'#90be6d', decoration:'#cdb4db', water:'#4cc9f0', fog:'#adb5bd', unknown:'#ff595e'
    }));
    function hslToRgb(h,s,l){ h/=360; s/=100; l/=100; const a = s*Math.min(l,1-l); const f = n=>{const k=(n+h*12)%12;const c=l-a*Math.max(Math.min(k-3,9-k,1),-1);return Math.round(255*c)}; return `rgb(${f(0)},${f(8)},${f(4)})`; }
    function hashBright(s){ let h=0; for(let i=0;i<s.length;i++){ h=(h*31 + s.charCodeAt(i))>>>0 } return h%360; }
    function colorFor(cat){ return CAT_COLORS.get(cat) || hslToRgb(hashBright(cat), 75, 60); }
    function colorForGroup(group){ return colorFor(group||'unknown'); }
    function colorForSub(sub){ return colorFor(sub||'unknown'); }
    function grayscaleForKey(key){ const h = hashBright(key||''); const v = Math.round(60 + (h/360)*160); return `rgb(${v},${v},${v})`; }
    function colorForEntity(e){ const mode=(document.getElementById('colorMode')?.value||'sub'); if(mode==='group') return colorForGroup(e.catGroup); if(mode==='sub') return colorForSub(e.catSub); if(mode==='mono') return (document.getElementById('monoColor')?.value)||'#ffffff'; if(mode==='gray') return grayscaleForKey(e.catSub); return colorForSub(e.catSub); }

    function categorize(name){
      const n = (name||'').toLowerCase();
      if(/loot|pickup|chest|crate|barrel|container/.test(n)) return 'loot';
      if(/spawn|spawner/.test(n)) return 'spawner';
      if(/enemy|beast|mob/.test(n)) return 'enemy';
      if(/npc|vendor|trader/.test(n)) return 'npc';
      if(/vfx|fx/.test(n)) return 'vfx';
      if(/maplabel|map_marker|marker/.test(n)) return 'map';
      if(/teleport|portal|waypoint/.test(n)) return 'teleporter';
      if(/trigger/.test(n)) return 'trigger';
      if(/resource|ore|wood|stone|metal|mine/.test(n)) return 'resource';
      if(/tree|bush|grass|plant|flora/.test(n)) return 'tree';
      if(/rock|boulder|cliff/.test(n)) return 'rock';
      if(/camp|ruin|house|hut|village|town|city|building|structure/.test(n)) return 'building';
      if(/decor|prop|deco/.test(n)) return 'decoration';
      if(/water|well|lake|river/.test(n)) return 'water';
      if(/fog|shroud/.test(n)) return 'fog';
      return 'unknown';
    }

    // Build hierarchical filters (group -> sub, collapsible)
    const catsDiv = document.getElementById('cats');
    const groups = Array.from(new Set(entsAll.map(e=>e.catGroup))).sort();
    const activeGroups = new Set(groups);
    const allSubs = Array.from(new Set(entsAll.map(e=>e.catSub))).sort();
    const activeSubs = new Set(allSubs);
    const groupToSubs = new Map();
    for(const g of groups){
      const counts = new Map();
      for(const e of entsAll){ if(e.catGroup===g){ counts.set(e.catSub, (counts.get(e.catSub)||0)+1); } }
      groupToSubs.set(g, Array.from(counts.entries()).sort((a,b)=> a[0].localeCompare(b[0])));
    }

    // Color-by selector already in the header row
    const colorModeSel = document.getElementById('colorMode');
    const monoColorEl = document.getElementById('monoColor');
    const updateMonoVisibility = ()=>{ monoColorEl.style.display = colorModeSel.value==='mono' ? 'inline-block' : 'none'; };
    updateMonoVisibility();
    colorModeSel.addEventListener('change', ()=>{ updateMonoVisibility(); renderAll(); });
    monoColorEl.addEventListener('input', renderAll);

    function renderFilters(){
      catsDiv.innerHTML='';
      for(const g of groups){
        const total = entsAll.filter(e=>e.catGroup===g).length;
        const details = document.createElement('details'); details.open = false;
        const summary = document.createElement('summary');
        const label=document.createElement('label');
        const cb=document.createElement('input'); cb.type='checkbox'; cb.checked=activeGroups.has(g); cb.dataset.group=g;
        cb.addEventListener('change',()=>{
          const subsForG = groupToSubs.get(g) || [];
          if(cb.checked){
            activeGroups.add(g);
            for(const [s] of subsForG){ activeSubs.add(s); }
          } else {
            activeGroups.delete(g);
            for(const [s] of subsForG){ if(activeSubs.has(s)) activeSubs.delete(s); }
          }
          renderFilters(); renderAll();
        });
        const chip=document.createElement('span'); chip.className='chip'; chip.style.background=colorForGroup? colorForGroup(g): colorFor(g);
        const name=document.createElement('span'); name.textContent=' '+g;
        const count=document.createElement('span'); count.textContent=total.toString(); count.style.opacity='0.7'; count.style.marginLeft='6px';
        label.appendChild(cb); label.appendChild(chip); label.appendChild(name);
        summary.appendChild(label); summary.appendChild(count); details.appendChild(summary);
        const list = document.createElement('div'); list.style.margin='4px 0 6px 18px';
        const subs = groupToSubs.get(g) || [];
        for(const [s,c] of subs){
          if(!activeGroups.has(g)) { if(activeSubs.has(s)) activeSubs.delete(s); }
          const l=document.createElement('label'); const cbox=document.createElement('input'); cbox.type='checkbox'; cbox.checked=activeSubs.has(s) && activeGroups.has(g); cbox.dataset.sub=s; cbox.dataset.group=g;
          cbox.addEventListener('change',()=>{ if(cbox.checked) activeSubs.add(s); else activeSubs.delete(s); renderAll(); });
          const subChip=document.createElement('span'); subChip.className='chip'; subChip.style.background=colorForSub? colorForSub(s): colorFor(s);
          const txt=document.createTextNode(' '+s);
          const cnt=document.createElement('span'); cnt.textContent=c.toString(); cnt.style.opacity='0.7'; cnt.style.marginLeft='6px';
          l.appendChild(cbox); l.appendChild(subChip); l.appendChild(txt); list.appendChild(l); list.appendChild(cnt);
        }
        details.appendChild(list);
        catsDiv.appendChild(details);
      }
    }
    renderFilters();
    document.getElementById('allOn').onclick=()=>{ activeGroups.clear(); groups.forEach(g=>activeGroups.add(g)); activeSubs.clear(); allSubs.forEach(s=>activeSubs.add(s)); renderFilters(); renderAll(); };
    document.getElementById('allOff').onclick=()=>{ activeGroups.clear(); activeSubs.clear(); renderFilters(); renderAll(); };

    // Controls
    const mode3dEl = document.getElementById('mode3d');
    const gridEl = document.getElementById('showGrid');
    const coverageEl = document.getElementById('showCoverage');
    const terrainEl = document.getElementById('showTerrain');
    const terrainOpts = document.getElementById('terrainOpts');
    const terrainColorSel = document.getElementById('terrainColor');
    const terrainSmoothEl = document.getElementById('terrainSmooth');
    const terrainPctEl = document.getElementById('terrainPct');
    const terrainPctVal = document.getElementById('terrainPctVal');
    const terrainOpacityEl = document.getElementById('terrainOpacity');
    const ptSizeEl = document.getElementById('ptSize');
    [mode3dEl, gridEl, ptSizeEl, coverageEl, terrainEl, terrainColorSel, terrainSmoothEl, terrainPctEl, terrainOpacityEl].forEach(el=> el.addEventListener('input', renderAll));
    gridEl.addEventListener('input', ()=>{ if(grid3d) grid3d.visible = gridEl.checked; });
    terrainEl.addEventListener('input', ()=>{ terrainOpts.style.display = terrainEl.checked ? 'inline-flex' : 'none'; });
    if(terrainPctEl && terrainPctVal){ terrainPctEl.addEventListener('input', ()=>{ terrainPctVal.textContent = `${terrainPctEl.value}%`; }); }
    mode3dEl.addEventListener('change', ()=>{
      const on = mode3dEl.checked;
      glContainer.style.display = on ? 'block' : 'none';
      canvas.style.display = on ? 'none' : 'block';
      if(on && !renderer){ init3D(); }
      renderAll();
    });

    function draw(){
      const w = canvas.width, h = canvas.height;
      ctx.clearRect(0,0,w,h);
      const gx = MAP_DATA.grid.x, gy = MAP_DATA.grid.y;
      const pad = 20, gw = w - pad*2, gh = h - pad*2;
      const cellW = gw / gx, cellH = gh / gy;
      if(gridEl.checked){
        ctx.strokeStyle = '#1d2a33'; ctx.lineWidth = 1;
        for(let y=0;y<=gy;y++){ const yy = pad + y*cellH; ctx.beginPath(); ctx.moveTo(pad, yy); ctx.lineTo(pad+gw, yy); ctx.stroke(); }
        for(let x=0;x<=gx;x++){ const xx = pad + x*cellW; ctx.beginPath(); ctx.moveTo(xx, pad); ctx.lineTo(xx, pad+gh); ctx.stroke(); }
      }
      if(coverageEl.checked){
        ctx.fillStyle = 'rgba(255,255,255,0.03)';
        for(let y=0;y<gy;y++) for(let x=0;x<gx;x++){
          if(coverageCounts[y][x]===0){ ctx.fillRect(pad + x*cellW+1, pad + y*cellH+1, cellW-2, cellH-2); }
        }
      }
      const ents = entsAll.filter(e=> activeGroups.has(e.catGroup) && activeSubs.has(e.catSub));
      let minX=Infinity,maxX=-Infinity,minZ=Infinity,maxZ=-Infinity;
      for(const e of ents){ if(!isFinite(e.x)||!isFinite(e.z)) continue; if(e.x<minX)minX=e.x; if(e.x>maxX)maxX=e.x; if(e.z<minZ)minZ=e.z; if(e.z>maxZ)maxZ=e.z; }
      let useTileCenters = !isFinite(minX)||!isFinite(minZ)||minX===maxX||minZ===maxZ;
      if(useTileCenters){
        for(const e of ents){ const cx = pad + (e.tileX+0.5)*cellW; const cy = pad + (e.tileY+0.5)*cellH; ctx.fillStyle = colorForEntity(e); const s = Math.max(0.5, parseFloat(ptSizeEl.value)); ctx.fillRect(cx-s/2, cy-s/2, s, s); }
      } else {
        const sx = gw/(maxX-minX), sz = gh/(maxZ-minZ);
        for(const e of ents){ const xx = pad + (e.x-minX)*sx; const yy = pad + (e.z-minZ)*sz; ctx.fillStyle = colorForEntity(e); const s = Math.max(0.5, parseFloat(ptSizeEl.value)); ctx.fillRect(xx-s/2, yy-s/2, s, s); }
      }
      document.getElementById('ents').textContent = ents.length.toString();
    }

    // 3D view (Three.js)
    var scene, camera, renderer, controls, instanced, grid3d, terrainMesh; // use var to avoid TDZ in early resize
    var terrainTileYs;
    function init3D(){
      if(!window.THREE || !window.OrbitControls){ console.warn('Three.js not available'); return; }
      scene = new THREE.Scene();
      scene.background = new THREE.Color(0x060a0d);
      camera = new THREE.PerspectiveCamera(60, glContainer.clientWidth/Math.max(1,glContainer.clientHeight), 0.1, 1000);
      renderer = new THREE.WebGLRenderer({antialias:true});
      renderer.setSize(glContainer.clientWidth, glContainer.clientHeight, false);
      glContainer.innerHTML = '';
      glContainer.appendChild(renderer.domElement);
      controls = new window.OrbitControls(camera, renderer.domElement);
      controls.enableDamping = true;
      const amb = new THREE.AmbientLight(0xffffff, 0.6); scene.add(amb);
      const hemi = new THREE.HemisphereLight(0xffffff, 0x223344, 0.6); scene.add(hemi);
      grid3d = new THREE.GridHelper(100, MAP_DATA.grid.x, 0x3a5360, 0x2c3e47); grid3d.position.y = -0.01; grid3d.visible = !!document.getElementById('showGrid')?.checked; scene.add(grid3d);
      camera.position.set(50, 60, 80);
      controls.target.set(0,0,0);
      controls.update();
      animate();
    }

    function ensureTerrain(){
      if(!scene || terrainMesh || !window.THREE) return;
      const gx = MAP_DATA.grid.x, gy = MAP_DATA.grid.y;
      terrainTileYs = Array.from({length: gy}, ()=>Array.from({length: gx}, ()=>[]));
      for(const e of entsAll){ if(Number.isFinite(e.y) && e.tileX>=0&&e.tileX<gx&&e.tileY>=0&&e.tileY<gy){ terrainTileYs[e.tileY][e.tileX].push(e.y); } }
      for(let y=0;y<gy;y++) for(let x=0;x<gx;x++){ terrainTileYs[y][x].sort((a,b)=>a-b); }

      const vertexCount = gx * gy;
      const positions = new Float32Array(vertexCount * 3);
      let pIndex = 0;
      for(let iy=0; iy<gy; iy++){
        const zVal = sceneZFromTile(iy);
        for(let ix=0; ix<gx; ix++){
          positions[pIndex++] = sceneXFromTile(ix);
          positions[pIndex++] = 0;
          positions[pIndex++] = zVal;
        }
      }
      const quadCount = Math.max(0, (gx-1)*(gy-1));
      const indexArray = (vertexCount > 65535 ? new Uint32Array(quadCount*6) : new Uint16Array(quadCount*6));
      let k=0;
      for(let iy=0; iy<gy-1; iy++){
        for(let ix=0; ix<gx-1; ix++){
          const a = iy*gx + ix;
          const b = a + 1;
          const c = (iy+1)*gx + ix;
          const d = c + 1;
          indexArray[k++] = a;
          indexArray[k++] = c;
          indexArray[k++] = b;
          indexArray[k++] = b;
          indexArray[k++] = c;
          indexArray[k++] = d;
        }
      }

      const geom = new THREE.BufferGeometry();
      geom.setAttribute('position', new THREE.BufferAttribute(positions,3));
      if(indexArray.length){ geom.setIndex(new THREE.BufferAttribute(indexArray,1)); }
      geom.computeVertexNormals();

      const mat = new THREE.MeshStandardMaterial({ color: 0x2a3b44, metalness: 0, roughness: 1, side: THREE.DoubleSide, polygonOffset:true, polygonOffsetFactor:1, polygonOffsetUnits:1, vertexColors: false, transparent: true, opacity: parseFloat((document.getElementById('terrainOpacity')?.value)||'0.85') });
      terrainMesh = new THREE.Mesh(geom, mat);
      terrainMesh.visible = !!document.getElementById('showTerrain')?.checked;
      scene.add(terrainMesh);
    }

    function smoothHeights(h, passes){
      const gy=h.length, gx=h[0].length; let a=h.map(row=>row.slice()), b=Array.from({length:gy},()=>Array.from({length:gx},()=>0));
      const clamp=(v,min,max)=> v<min?min:(v>max?max:v);
      for(let p=0;p<passes;p++){
        // horizontal
        for(let y=0;y<gy;y++){
          for(let x=0;x<gx;x++){
            const x0=clamp(x-1,0,gx-1), x1=x, x2=clamp(x+1,0,gx-1);
            b[y][x]=(a[y][x0]+a[y][x1]+a[y][x2])/3;
          }
        }
        // vertical
        for(let y=0;y<gy;y++){
          for(let x=0;x<gx;x++){
            const y0=clamp(y-1,0,gy-1), y1=y, y2=clamp(y+1,0,gy-1);
            a[y][x]=(b[y0][x]+b[y1][x]+b[y2][x])/3;
          }
        }
      }
      return a;
    }

    function fillMissingHeights(arr){
      const gy=arr.length, gx=arr[0].length; const out = arr.map(row=>row.slice());
      const dirs=[[1,0],[-1,0],[0,1],[0,-1],[1,1],[-1,1],[1,-1],[-1,-1]];
      let changed=true, iter=0, maxIter=gy+gx;
      while(changed && iter++<maxIter){
        changed=false;
        for(let y=0;y<gy;y++) for(let x=0;x<gx;x++) if(!Number.isFinite(out[y][x])){
          let sum=0, n=0; for(const [dx,dy] of dirs){ const xx=x+dx, yy=y+dy; if(xx>=0&&xx<gx&&yy>=0&&yy<gy){ const v=out[yy][xx]; if(Number.isFinite(v)){ sum+=v; n++; } } }
          if(n>0){ out[y][x]=sum/n; changed=true; }
        }
      }
      let mn=Infinity; for(let y=0;y<gy;y++) for(let x=0;x<gx;x++){ const v=out[y][x]; if(Number.isFinite(v)&&v<mn) mn=v; }
      for(let y=0;y<gy;y++) for(let x=0;x<gx;x++) if(!Number.isFinite(out[y][x])) out[y][x]=mn;
      return out;
    }

    function heightsFromPercentile(p){
      const gx = MAP_DATA.grid.x, gy = MAP_DATA.grid.y;
      const heights = Array.from({length: gy}, ()=>Array.from({length: gx}, ()=>NaN));
      let hmin=Infinity, hmax=-Infinity;
      for(let y=0;y<gy;y++) for(let x=0;x<gx;x++){
        const ys = terrainTileYs?.[y]?.[x]||[]; if(ys.length){ const idx = Math.min(ys.length-1, Math.max(0, Math.floor(ys.length*(p/100)))); const h = ys[idx]; heights[y][x]=h; if(h<hmin)hmin=h; if(h>hmax)hmax=h; }
      }
      const filled = fillMissingHeights(heights);
      return {heights: filled, hmin, hmax};
    }

    function heightToColor(t){
      // simple gradient: deep -> low -> mid -> high -> peak
      const stops=[ [0.00,[20,30,60]],[0.25,[40,80,120]],[0.50,[50,120,60]],[0.70,[160,140,60]],[0.85,[110,80,60]],[1.00,[240,240,240]] ];
      for(let i=1;i<stops.length;i++) if(t<=stops[i][0]){ const [t0,c0]=stops[i-1], [t1,c1]=stops[i]; const k=(t-t0)/(t1-t0); const c=[ Math.round(c0[0]+(c1[0]-c0[0])*k), Math.round(c0[1]+(c1[1]-c0[1])*k), Math.round(c0[2]+(c1[2]-c0[2])*k) ]; return (new THREE.Color(`rgb(${c[0]},${c[1]},${c[2]})`)); }
      return new THREE.Color(0x888888);
    }

    function updateTerrain(){
      if(!terrainMesh || !terrainTileYs) return;
      const gx = MAP_DATA.grid.x, gy = MAP_DATA.grid.y;
      const passes = parseInt(terrainSmoothEl.value||'0',10);
      const pct = parseInt((document.getElementById('terrainPct')?.value)||'75',10);
      const res = heightsFromPercentile(pct);
      const heights = passes>0 ? smoothHeights(res.heights, passes) : res.heights;
      let hmin=res.hmin, hmax=res.hmax; if(!Number.isFinite(hmin)||!Number.isFinite(hmax)||hmin===hmax){ hmin=0; hmax=1; }
      const range=Math.max(1e-6, hmax-hmin), H=50;
      const pos = terrainMesh.geometry.attributes.position;
      for(let iy=0; iy<gy; iy++){
        for(let ix=0; ix<gx; ix++){
          const idx = iy*gx + ix; const h=heights[iy][ix]; const py = ((h-hmin)/range - 0.5)*H; pos.setY(idx, py);
        }
      }
      pos.needsUpdate = true; terrainMesh.geometry.computeVertexNormals();
      const colorMode = terrainColorSel.value;
      if(colorMode==='height'){
        const colAttr = new THREE.Float32BufferAttribute(new Float32Array(gx*gy*3),3);
        let k=0; for(let iy=0;iy<gy;iy++) for(let ix=0;ix<gx;ix++){ const t=(heights[iy][ix]-hmin)/range; const c=heightToColor(t); colAttr.array[k++]=c.r; colAttr.array[k++]=c.g; colAttr.array[k++]=c.b; }
        terrainMesh.geometry.setAttribute('color', colAttr);
        if(!terrainMesh.material.vertexColors){ terrainMesh.material.dispose(); terrainMesh.material = new THREE.MeshStandardMaterial({vertexColors:true, metalness:0, roughness:1, side:THREE.DoubleSide, polygonOffset:true, polygonOffsetFactor:1, polygonOffsetUnits:1, transparent:true, opacity: parseFloat((document.getElementById('terrainOpacity')?.value)||'0.85')}); }
      } else {
        terrainMesh.geometry.deleteAttribute?.('color');
        if(terrainMesh.material.vertexColors){ terrainMesh.material.dispose(); terrainMesh.material = new THREE.MeshStandardMaterial({ color: 0x2a3b44, metalness:0, roughness:1, side:THREE.DoubleSide, polygonOffset:true, polygonOffsetFactor:1, polygonOffsetUnits:1, transparent:true, opacity: parseFloat((document.getElementById('terrainOpacity')?.value)||'0.85') }); }
      }
      const op = parseFloat((document.getElementById('terrainOpacity')?.value)||'0.85');
      terrainMesh.material.opacity = op; terrainMesh.material.transparent = op < 1;
    }

    function update3D(){
      if(!scene) return;
      // cleanup previous mesh
      if(instanced){
        if(Array.isArray(instanced)){
          for(const mesh of instanced){ scene.remove(mesh); mesh.geometry.dispose(); mesh.material.dispose(); }
        } else { scene.remove(instanced); instanced.geometry.dispose(); instanced.material.dispose(); }
        instanced = null;
      }
      if(terrainMesh){ terrainMesh.visible = !!document.getElementById('showTerrain')?.checked; }
      const ents = entsAll.filter(e=> activeGroups.has(e.catGroup) && activeSubs.has(e.catSub));
      const minY = WORLD.minY, maxY = WORLD.maxY;
      const yRange = maxY - minY;
      const invY = Math.abs(yRange) > 1e-6 ? 1 / yRange : 0;
      const W = TERRAIN_WIDTH, D = TERRAIN_DEPTH, H = TERRAIN_HEIGHT;
      const geom = new THREE.BoxGeometry(1,1,1);
      const size = Math.max(0.25, parseFloat(ptSizeEl.value))/2;
      const dummy = new THREE.Object3D();
      // Bucket instances by color to ensure visible colors even if instanceColor is unsupported
      const buckets = new Map(); // colorString -> array of e
      for(const e of ents){
        const col = colorForEntity(e);
        if(!buckets.has(col)) buckets.set(col, []);
        buckets.get(col).push(e);
      }
      const meshes = [];
      for(const [col, arr] of buckets.entries()){
        const mat = new THREE.MeshBasicMaterial({color: new THREE.Color(col), toneMapped: false});
        const mesh = new THREE.InstancedMesh(geom, mat, arr.length);
        let i=0;
        for(const e of arr){
          const tileFX = tileCenterX(e);
          const tileFZ = tileCenterZ(e);
          const px = sceneXFromTile(tileFX);
          const pz = sceneZFromTile(tileFZ);
          let ny = invY ? ((Number.isFinite(e.y) ? e.y : (minY + maxY)/2) - minY) * invY : 0.5;
          if(!Number.isFinite(ny)) ny = 0.5;
          ny = Math.min(Math.max(ny, 0), 1);
          const py = (ny - 0.5) * H;
          dummy.position.set(px, py, pz);
          dummy.scale.set(size, size, size);
          dummy.updateMatrix();
          mesh.setMatrixAt(i++, dummy.matrix);
        }
        mesh.instanceMatrix.needsUpdate = true;
        scene.add(mesh);
        meshes.push(mesh);
      }
      instanced = meshes;
      document.getElementById('ents').textContent = ents.length.toString();
    }

    function animate(){ requestAnimationFrame(animate); if(controls) controls.update(); if(renderer && scene && camera){ renderer.render(scene, camera); } }

    function renderAll(){ if(mode3dEl.checked){ ensureTerrain(); updateTerrain(); update3D(); } else { draw(); } }

    // info bar
    document.getElementById('world').textContent = MAP_DATA.worldGuid;
    document.getElementById('grid').textContent = MAP_DATA.grid.x + 'x' + MAP_DATA.grid.y;
    document.getElementById('chunks').textContent = MAP_DATA.chunks.length;
    document.getElementById('ents').textContent = (MAP_DATA.entities||[]).length;

    resize();
  </script>
</body>
</html>
'@

# Inline JSON data
$jsonOpts = @{ Depth = 8; Compress = $true }
$json = $out | ConvertTo-Json @jsonOpts
$jsonSafe = $json -replace '</script>','<\/script>'
$htmlFinal = $html.Replace('__JSON__', $jsonSafe)
Write-Progress -Activity $activity -Status 'Composed HTML' -PercentComplete 80

# Inject Three.js data/module URLs (fallback to CDN esm.sh if inline fetch failed)
$threeUrlToUse = $threeDataUrl
if([string]::IsNullOrWhiteSpace($threeUrlToUse)) { $threeUrlToUse = 'https://esm.sh/three@0.158.0' }
$orbitUrlToUse = $orbitDataUrl
if([string]::IsNullOrWhiteSpace($orbitUrlToUse)) { $orbitUrlToUse = 'https://esm.sh/three@0.158.0/examples/jsm/controls/OrbitControls.js' }
$htmlFinal = $htmlFinal.Replace('__THREE_DATAURL__', $threeUrlToUse)
$htmlFinal = $htmlFinal.Replace('__ORBIT_DATAURL__', $orbitUrlToUse)

$outHtml = Join-Path $OutDir 'index.html'
Set-Content -LiteralPath $outHtml -Value $htmlFinal -Encoding UTF8

Write-Host "Viewer generated: $outHtml"
Write-Progress -Activity $activity -Completed
