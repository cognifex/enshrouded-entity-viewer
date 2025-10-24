param(
  [string]$UnpackedRoot = "unpacked",
  [string]$OutPath = "viewer/map-data.json",
  [int]$MaxEntitiesPerChunk = 300,
  [int]$MaxChunks = 0,
  [switch]$OnlyLayer0,
  [switch]$SkipTemplateLookup,
  [switch]$Parallel,
  [int]$ThrottleLimit = 4,
  [switch]$WriteShards,
  [int]$ShardSize = 100000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Json($path){
  try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Find-FirstFile($dir, $pattern){
  $f = Get-ChildItem -LiteralPath $dir -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $f){ return $null }
  return $f.FullName
}

# Discover world grid size from SceneResource or VoxelWorldResource
$sceneResDir = Join-Path $UnpackedRoot 'SceneResource'
$voxelWorldResDir = Join-Path $UnpackedRoot 'VoxelWorldResource'

$countX = 40; $countY = 40; $worldGuid = $null
$sceneResPath = $null
$sceneCandidates = Get-ChildItem -LiteralPath $sceneResDir -Filter '*.json' -File -ErrorAction SilentlyContinue
if($sceneCandidates){
  $bestArea = -1
  foreach($f in $sceneCandidates){
    $s = Get-Json $f.FullName
    if(-not $s){ continue }
    if($s.entityChunkCount){
      $cx = [int]$s.entityChunkCount.x
      $cy = [int]$s.entityChunkCount.y
      $area = $cx * $cy
      if($area -gt $bestArea){ $bestArea=$area; $sceneResPath=$f.FullName; $countX=$cx; $countY=$cy; $worldGuid=$s.'$guid' }
    }
  }
}

if(-not $worldGuid){
  $vwFiles = Get-ChildItem -LiteralPath $voxelWorldResDir -Filter '*_75f48072_0.json' -File -ErrorAction SilentlyContinue
  if($vwFiles){
    $bestArea = -1
    foreach($f in $vwFiles){
      $vw = Get-Json $f.FullName
      if(-not $vw){ continue }
      if($vw.tileCount){
        $cx = [int]$vw.tileCount.x; $cy = [int]$vw.tileCount.y
        $area = $cx*$cy
        if($area -gt $bestArea){ $bestArea=$area; $worldGuid=$vw.'$guid'; $countX=$cx; $countY=$cy }
      }
    }
  }
}

if(-not $worldGuid){ throw "Could not determine world GUID or grid size." }

$layerSize = $countX * $countY

# Prepare caches and output containers
$tmplDir = Join-Path $UnpackedRoot 'TemplateResource'
$sceneChunkDir = Join-Path $UnpackedRoot 'SceneEntityChunkResource'

$templateCache = @{}
$chunks = New-Object System.Collections.ArrayList
$entities = New-Object System.Collections.ArrayList
$templateGuidsUsed = New-Object System.Collections.Generic.HashSet[string]
$voxelInfo = $null

function Get-TemplateInfo([string]$guid){
  if([string]::IsNullOrWhiteSpace($guid)){ return $null }
  if($templateCache.ContainsKey($guid)){ return $templateCache[$guid] }
  $path = Find-FirstFile $tmplDir ("$guid*.json")
  $name = $null
  if($path){
    $tj = Get-Json $path
    if($tj -and ($tj.PSObject.Properties.Name -contains 'name')){ $name = $tj.name }
  }
  $info = [PSCustomObject]@{ guid=$guid; name=$name; path=$path }
  $templateCache[$guid] = $info
  return $info
}

Write-Host "World: $worldGuid, grid: ${countX}x${countY} (layerSize=$layerSize)"

# Enumerate scene chunks
$chunkFiles = Get-ChildItem -LiteralPath $sceneChunkDir -Filter '*.json' -File -ErrorAction SilentlyContinue
if(-not $chunkFiles){ throw "No SceneEntityChunkResource JSON files found." }
if($MaxChunks -gt 0){ $chunkFiles = $chunkFiles | Select-Object -First $MaxChunks }

$total = ($chunkFiles | Measure-Object).Count
$processed = 0
$addedEntities = 0

Write-Host ("Parallel: {0}, ThrottleLimit: {1}, Shards: {2} (size {3})" -f ($Parallel.IsPresent), $ThrottleLimit, ($WriteShards.IsPresent), $ShardSize)

$writeShardsActive = $WriteShards.IsPresent
$shardDir = ''
if($writeShardsActive){
  if(Test-Path -LiteralPath $OutPath){
    $item = Get-Item -LiteralPath $OutPath
    if($item.PSIsContainer){
      $shardDir = $item.FullName
    } else {
      $parent = Split-Path -Parent -Path $OutPath
      $base = [IO.Path]::GetFileNameWithoutExtension($OutPath)
      if([string]::IsNullOrWhiteSpace($base)){ $base = 'data' }
      $cand = Join-Path $parent $base
      if((Test-Path -LiteralPath $cand) -and -not (Get-Item $cand).PSIsContainer){ $cand = Join-Path $parent ($base + '-shards') }
      if(-not (Test-Path -LiteralPath $cand)){ New-Item -ItemType Directory -Path $cand | Out-Null }
      $shardDir = $cand
    }
  } else {
    # Create directory at OutPath
    New-Item -ItemType Directory -Path $OutPath | Out-Null
    $shardDir = (Get-Item -LiteralPath $OutPath).FullName
  }
}
$shardBuffer = New-Object System.Collections.ArrayList
$shardIndex = 0
function Flush-Shard{
  if(-not $writeShardsActive){ return }
  if(($script:shardBuffer | Measure-Object).Count -eq 0){ return }
  $script:shardIndex++
  $name = ('entities-{0:D5}.json' -f $script:shardIndex)
  $path = Join-Path $script:shardDir $name
  ($script:shardBuffer | ConvertTo-Json -Depth 6 -Compress) | Set-Content -LiteralPath $path -Encoding UTF8
  Write-Host "Wrote shard: $path (count=$(($script:shardBuffer|Measure-Object).Count))"
  $script:shardBuffer.Clear() | Out-Null
}

if($Parallel){
  $chunkFiles | ForEach-Object -Parallel {
    function Get-Json { param([string]$path) try { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $null } }
    $j = Get-Json $_.FullName; if(-not $j){ return }
    $part = [int]$j.'$part'
    $layer = [int][math]::Floor($part / $using:layerSize)
    if($using:OnlyLayer0 -and $layer -ne 0){ return }
    $tileIndex = $part % $using:layerSize
    $tileX = $tileIndex % $using:countX
    $tileY = [int][math]::Floor($tileIndex / $using:countX)
    $entArr = @(); if($j.entities){ $entArr = $j.entities }
    $tmplArr = @(); if($j.templates){ $tmplArr = $j.templates }
    $chunkEntCount = ($entArr | Measure-Object).Count
    $take = [Math]::Min($using:MaxEntitiesPerChunk, $chunkEntCount)
    $entsOut = New-Object System.Collections.ArrayList
    for($i=0; $i -lt $take; $i++){
      $e = $entArr[$i]; if(-not $e){ continue }
      $idx = $e.index
      $tmplGuid = $null
      if($idx -ne $null -and $idx -ge 0 -and $idx -lt $tmplArr.Count){ $tmplGuid = $tmplArr[$idx] }
      $pos = $e.transform.position
      $rot = $e.transform.orientation
      $scl = $e.transform.scale
      $obj = [PSCustomObject]@{
        part=$part; layer=$layer; tileX=$tileX; tileY=$tileY; entityIndex=$i;
        templateGuid=$tmplGuid; templateName=$null;
        x=[double]$pos.x; y=[double]$pos.y; z=[double]$pos.z;
        rw=[double]$rot.w; rx=[double]$rot.x; ry=[double]$rot.y; rz=[double]$rot.z;
        sx=[double]$scl.x; sy=[double]$scl.y; sz=[double]$scl.z;
      }
      [void]$entsOut.Add($obj)
    }
    [PSCustomObject]@{
      chunk = [PSCustomObject]@{ part=$part; layer=$layer; tileX=$tileX; tileY=$tileY; entityCount=$chunkEntCount; path=$_.FullName }
      entities = $entsOut
    }
  } -ThrottleLimit $ThrottleLimit | ForEach-Object {
    if($_ -eq $null){ return }
    [void]$chunks.Add($_.chunk)
    foreach($en in $_.entities){ if($en.templateGuid){ [void]$templateGuidsUsed.Add([string]$en.templateGuid) } }
    $addedEntities += ($_.entities | Measure-Object).Count
    if($writeShardsActive){ foreach($e in $_.entities){ [void]$shardBuffer.Add($e) }; if(($shardBuffer|Measure-Object).Count -ge $ShardSize){ Flush-Shard } }
    else { foreach($e in $_.entities){ [void]$entities.Add($e) } }
    $processed++
    if(($processed % 25) -eq 0 -or $processed -eq $total){
      $pct = [int](100 * $processed / [Math]::Max(1,$total))
      Write-Progress -Activity "Parsing chunks (parallel)" -Status "$processed / $total, entities: $addedEntities" -PercentComplete $pct
    }
  }
} else {
  foreach($cf in $chunkFiles){
    $j = Get-Json $cf.FullName
    if(-not $j){ continue }
    $part = [int]$j.'$part'
    $layer = [int][math]::Floor($part / $layerSize)
    if($OnlyLayer0 -and $layer -ne 0){ continue }
    $tileIndex = $part % $layerSize
    $tileX = $tileIndex % $countX
    $tileY = [int][math]::Floor($tileIndex / $countX)
    $entArr = @(); if($j.entities){ $entArr = $j.entities }
    $tmplArr = @(); if($j.templates){ $tmplArr = $j.templates }
    $chunkEntCount = ($entArr | Measure-Object).Count
    [void]$chunks.Add([PSCustomObject]@{ part=$part; layer=$layer; tileX=$tileX; tileY=$tileY; entityCount=$chunkEntCount; path=$cf.FullName })
    if($chunkEntCount -eq 0){ continue }
    $take = [Math]::Min($MaxEntitiesPerChunk, $chunkEntCount)
    for($i=0; $i -lt $take; $i++){
      $e = $entArr[$i]; if(-not $e){ continue }
      $idx = $e.index
      $tmplGuid = $null
      if($idx -ne $null -and $idx -ge 0 -and $idx -lt $tmplArr.Count){ $tmplGuid = $tmplArr[$idx] }
      if($tmplGuid){ [void]$templateGuidsUsed.Add([string]$tmplGuid) }
      $tmplInfo = $null
      $tmplName = $null
      if(-not $SkipTemplateLookup){ $tmplInfo = Get-TemplateInfo $tmplGuid; if($tmplInfo){ $tmplName=$tmplInfo.name } }
      $pos = $e.transform.position; $rot = $e.transform.orientation; $scl = $e.transform.scale
      $obj = [PSCustomObject]@{
        part=$part; layer=$layer; tileX=$tileX; tileY=$tileY; entityIndex=$i;
        templateGuid=$tmplGuid; templateName=$tmplName;
        x=[double]$pos.x; y=[double]$pos.y; z=[double]$pos.z;
        rw=[double]$rot.w; rx=[double]$rot.x; ry=[double]$rot.y; rz=[double]$rot.z;
        sx=[double]$scl.x; sy=[double]$scl.y; sz=[double]$scl.z;
      }
      if($writeShardsActive){ [void]$shardBuffer.Add($obj); if(($shardBuffer|Measure-Object).Count -ge $ShardSize){ Flush-Shard } }
      else { [void]$entities.Add($obj) }
      $addedEntities++
    }
    $processed++
    if(($processed % 25) -eq 0 -or $processed -eq $total){
      $pct = [int](100 * $processed / [Math]::Max(1,$total))
      Write-Progress -Activity "Parsing chunks" -Status "$processed / $total, entities: $addedEntities" -PercentComplete $pct
    }
  }
}
Write-Progress -Activity "Parsing chunks" -Completed
if($writeShardsActive){ Flush-Shard }

# Populate template cache from used GUIDs if requested
if(-not $SkipTemplateLookup){
  foreach($gid in $templateGuidsUsed){ if($gid){ $null = Get-TemplateInfo $gid } }
}

# If writing shards, emit meta.json and exit
if($writeShardsActive){
  $meta = [PSCustomObject]@{
    worldGuid=$worldGuid
    grid = @{ x=$countX; y=$countY; layerSize=$layerSize }
    chunks=$chunks
    templates=@()
    voxel=$null
  }
  if(-not $SkipTemplateLookup){ foreach($k in $templateCache.Keys){ $meta.templates += @{ guid=$k; name=$templateCache[$k].name; path=$templateCache[$k].path } } }
  $metaPath = Join-Path $shardDir 'meta.json'
  $meta | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $metaPath -Encoding UTF8
  Write-Host "Meta written: $metaPath"
  Write-Host ("Summary -> chunks: {0}, entities (approx in shards): {1}, shards: {2}" -f (($chunks|Measure-Object).Count), $addedEntities, $shardIndex)
  return
}

$out = [PSCustomObject]@{
  worldGuid=$worldGuid
  grid = @{ x=$countX; y=$countY; layerSize=$layerSize }
  chunks=$chunks
  entities=$entities
  templates=$templateCache.GetEnumerator() | ForEach-Object { @{ guid=$_.Key; name=$_.Value.name; path=$_.Value.path } }
  voxel=$null
}

# Try parse VoxelWorldResource and Fog bounds
try {
  $vwrDir = Join-Path $UnpackedRoot 'VoxelWorldResource'
  $vwr = Get-ChildItem -LiteralPath $vwrDir -Filter "${worldGuid}_75f48072_0.json" -File -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $vwr){ $vwr = Get-ChildItem -LiteralPath $vwrDir -Filter '*_75f48072_0.json' -File -ErrorAction SilentlyContinue | Where-Object { try{ (Get-Content $_.FullName -Raw | ConvertFrom-Json).tileCount.x -gt 1 } catch { $false } } | Select-Object -First 1 }
  if($vwr){
    $vj = Get-Content $vwr.FullName -Raw | ConvertFrom-Json
    $voxelInfo = @{
      guid = $vj.'$guid'
      tileCount = @{ x=[int]$vj.tileCount.x; y=[int]$vj.tileCount.y }
      origin = @{ x=[double]$vj.origin.x; y=[double]$vj.origin.y; z=[double]$vj.origin.z }
      lowLODMaxLevel = [int]$vj.lowLODMaxLevel
    }
    # Fog bounds (to estimate vertical range)
    $fogDir = Join-Path $UnpackedRoot 'FogVoxelMappingResource'
    $fog = Get-ChildItem -LiteralPath $fogDir -Filter '*_e4053c64_0.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if($fog){
      $fj = Get-Content $fog.FullName -Raw | ConvertFrom-Json
      if($fj.mapping -and $fj.mapping.Count -gt 0){
        $bb = $fj.mapping[0].boundingBox
        $voxelInfo.bounds = @{ min=@{x=[double]$bb.min.x;y=[double]$bb.min.y;z=[double]$bb.min.z}; max=@{x=[double]$bb.max.x;y=[double]$bb.max.y;z=[double]$bb.max.z} }
      }
    }
    # Build coarse height map from entity Y per tile (upper quartile)
    $per = @{}
    foreach($e in $entities){ $k = ($e.tileY,'_', $e.tileX) -join ''; if(-not $per.ContainsKey($k)){ $per[$k] = New-Object System.Collections.ArrayList }
      if($e.y -ne $null){ [void]$per[$k].Add([double]$e.y) } }
    $hmap = @(); $hmin=[double]::PositiveInfinity; $hmax=[double]::NegativeInfinity
    for($ty=0;$ty -lt $countY;$ty++){
      $row = @()
      for($tx=0;$tx -lt $countX;$tx++){
        $k = ($ty,'_', $tx) -join ''
        $vals = @(); if($per.ContainsKey($k)){ $vals = [double[]]$per[$k].ToArray() }
        $h = $null
        if($vals.Length -gt 0){ [array]::Sort($vals); $idx=[int][math]::Floor($vals.Length*0.75); if($idx -ge $vals.Length){ $idx=$vals.Length-1 }; $h=$vals[$idx]; if($h -lt $hmin){ $hmin=$h }; if($h -gt $hmax){ $hmax=$h } }
        $row += $h
      }
      $hmap += ,$row
    }
    $voxelInfo.heightMap = $hmap
    $voxelInfo.heightMin = $hmin
    $voxelInfo.heightMax = $hmax
    $out.voxel = $voxelInfo
  }
} catch { Write-Warning "Voxel parse failed: $_" }

# Ensure out folder
$outDir = Split-Path -Parent -Path $OutPath
if([string]::IsNullOrWhiteSpace($outDir)){ $outDir = '.' }
if(-not (Test-Path -LiteralPath $outDir)){ New-Item -ItemType Directory -Path $outDir | Out-Null }

$jsonOpts = @{ Depth = 8; Compress = $true }
$out | ConvertTo-Json @jsonOpts | Set-Content -LiteralPath $OutPath -Encoding UTF8

Write-Host "Chunk data written: $OutPath"
Write-Host ("Summary -> chunks: {0}, entities: {1}" -f ($chunks | Measure-Object | % Count), ($entities | Measure-Object | % Count))
