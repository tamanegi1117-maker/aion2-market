# Fetch AION2 exchange prices (aion2.exchange) for crafted weapons, crafted accessories and
# crafting materials on every Elyos server, compare the home server against the other Asia
# servers, the Asia early-access servers and the global (NA/EU/LA) servers, and write
# output/items.json and output/crafts.json for the dashboard. Prints a short summary only.
param([int]$HomeServer = 11506)

$ErrorActionPreference = 'Stop'
$base = 'https://aion2.exchange/api'
$outDir = Join-Path $PSScriptRoot 'data'
New-Item -ItemType Directory -Force $outDir | Out-Null
$matNames = (Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot 'names_ja.json') | ConvertFrom-Json).materials

function Get-Api([string]$path) {
    for ($i = 1; $i -le 3; $i++) {
        try { return Invoke-RestMethod "$base/$path" -TimeoutSec 60 }
        catch { if ($i -eq 3) { throw "API failed ($path): $($_.Exception.Message)" }; Start-Sleep -Seconds (3 * $i) }
    }
}

function Get-Median($values) {
    $a = @($values | Where-Object { $null -ne $_ } | Sort-Object)
    if ($a.Count -eq 0) { return $null }
    $m = [math]::Floor($a.Count / 2)
    if ($a.Count % 2) { return [double]$a[$m] }
    return ([double]$a[$m - 1] + [double]$a[$m]) / 2
}

function Get-Pct($now, $ref) {
    if ($null -eq $now -or $null -eq $ref -or $ref -le 0) { return $null }
    return [math]::Round(($now / $ref - 1) * 100, 1)
}

function Round-Price($v) { if ($null -eq $v) { return $null }; return [long][math]::Round($v) }

# --- Japanese names for crafted equipment ------------------------------------------------
$tiers = @(
    @{ en = "Splendent True Dragon Lord "; ja = '光る真龍王の'; rank = 8 },
    @{ en = "True Dragon Lord ";           ja = '真龍王の';     rank = 7 },
    @{ en = "Artisan's Splendent ";        ja = '達人の光る';   rank = 6 },
    @{ en = "Artisan's ";                  ja = '達人の';       rank = 5 },
    @{ en = "Expert's Splendent ";         ja = '職人の光る';   rank = 4 },
    @{ en = "Expert's ";                   ja = '職人の';       rank = 3 },
    @{ en = "Splendent ";                  ja = '光る';         rank = 2 }
)
$stuff = @{ Orichalcum = 'オリハルコンの'; Ruby = 'ルビーの'; Sapphire = 'サファイアの'; Diamond = 'ダイヤモンドの'; Yggdrasil = 'ユグドラシルの'; Truth = '真実の' }
$parts = @{ Longsword = '長剣'; Guard = 'ガーダー'; Ring = '指輪'; Necklace = 'ネックレス'; Earrings = 'イヤリング'
            Greatsword = '大剣'; Dagger = '短剣'; Bow = '弓'; Orb = '宝珠'; Spellbook = '魔導書'; Staff = '杖'; Mace = 'メイス' }
$confirmed = @('Orichalcum', 'Ruby', 'Sapphire', 'Longsword', 'Guard', 'Ring', 'Necklace')

function Convert-EquipName([string]$en) {
    $rest = $en; $prefix = ''; $rank = 1
    foreach ($t in $tiers) { if ($rest.StartsWith($t.en)) { $prefix = $t.ja; $rank = $t.rank; $rest = $rest.Substring($t.en.Length); break } }
    $words = $rest -split ' '
    $part = $words[-1]; $mat = if ($words.Count -gt 1) { $words[0] } else { '' }
    $tentative = ($part -notin $confirmed) -or ($mat -and $mat -notin $confirmed)
    $ja = $prefix + $(if ($mat) { $stuff[$mat] } else { '' }) + $parts[$part]
    if (-not $parts[$part]) { $ja = $en; $tentative = $false }
    if ($tentative) { $ja += '(仮)' }
    return @{ ja = $ja; rank = $rank; part = $(if ($parts[$part]) { $parts[$part] } else { $part }) }
}

function Get-MaterialGroup([string]$en) {
    switch -Regex ($en) {
        'Wrathful'             { return '怒り' }
        'Odyle'                { return 'オード' }
        'Orichalcum'           { return 'オリハルコン' }
        'Gemstone|Decoration|Powder' { if ($en -notmatch 'Spiritstone') { return '宝石' } }
        'Log|Yggdrasil'        { return '木材' }
        'Balaur'               { return '龍族の素材' }
        'Refining|Spiritstone|Magic Crystal' { return '精錬石など' }
        'Leather|Meat|Fruit'   { return '革・食材' }
        default                { return '採集(薬草など)' }
    }
}

# Items the user crafts (longsword, guard, ring, necklace) and the materials they need.
function Test-Mine([string]$sec, [string]$en) {
    if ($sec -eq 'weapons') { return $en -match 'Longsword|Guard' }
    if ($sec -eq 'accessories') { return $en -match ' Ring$|Necklace' }
    return $en -match 'Wrathful|Odyle|Orichalcum|Ruby|Sapphire|Refining Stone|Balaur Horn|Balaur Scale'
}

# --- Servers -----------------------------------------------------------------------------
$servers = @((Get-Api 'servers').servers | Where-Object { $_.faction -eq 'Elyos' -and $_.has_data })
function Get-Group($s) {
    if ($s.server_id -eq $HomeServer) { return 'home' }
    if ($s.region -eq 'AS') { if (($s.server_id % 100) -le 3) { return 'early' } return 'asia' }
    return 'global'
}
$groupCount = @{ asia = 0; early = 0; global = 0 }
foreach ($s in $servers) { $g = Get-Group $s; if ($g -ne 'home') { $groupCount[$g]++ } }

$sections = 'weapons', 'accessories', 'materials'
function Test-Wanted([string]$sec, $it) {
    switch ($sec) {
        'weapons'     { return $it.name -match 'Orichalcum|Yggdrasil|Truth|True Dragon Lord' }
        'accessories' { return $it.name -match 'Diamond|Ruby|Sapphire|True Dragon Lord' }
        'materials'   { return $it.category.id -in 53, 54 }
    }
}

# --- Collect prices ----------------------------------------------------------------------
$obs = @{}
$capturedAt = $null
foreach ($s in $servers) {
    $g = Get-Group $s
    foreach ($sec in $sections) {
        $r = Get-Api "items?section=$sec&server=$($s.server_id)&offset=0&limit=500&window=7d"
        foreach ($it in $r.items) {
            if (-not (Test-Wanted $sec $it)) { continue }
            $k = [string]$it.item_key
            if (-not $obs.ContainsKey($k)) {
                $obs[$k] = @{ sec = $sec; en = $it.name; home = $null
                              asia = @(); early = @(); global = @(); chEarly = @(); chAsia = @(); chGlobal = @() }
            }
            $o = $obs[$k]
            if ($g -eq 'home') { $o.home = $it; if (-not $capturedAt) { $capturedAt = $it.captured_at }; continue }
            if ($it.listed -and $it.price) {
                $o[$g] += [double]$it.price
                if ($null -ne $it.change_pct) {
                    $chKey = @{ asia = 'chAsia'; early = 'chEarly'; global = 'chGlobal' }[$g]
                    $o[$chKey] += [double]$it.change_pct
                }
            }
        }
    }
}

# 24h change on the home server
$ch24 = @{}
foreach ($sec in $sections) {
    $r = Get-Api "items?section=$sec&server=$HomeServer&offset=0&limit=500&window=24h"
    foreach ($it in $r.items) { $ch24[[string]$it.item_key] = $it.change_pct }
}

# 7-day history on the home server (4h buckets)
$spark = @{}
$homeKeys = @($obs.Keys | Where-Object { $obs[$_].home -and $obs[$_].home.listed })
for ($i = 0; $i -lt $homeKeys.Count; $i += 40) {
    $batch = $homeKeys[$i..([math]::Min($i + 39, $homeKeys.Count - 1))]
    $r = Get-Api "sparklines?server=$HomeServer&keys=$($batch -join ',')&window=7d"
    foreach ($sl in $r.sparklines) { $spark[[string]$sl.item_key] = @($sl.points | Where-Object { $_.price } | ForEach-Object { [double]$_.price }) }
}

# --- Build rows --------------------------------------------------------------------------
$rows = foreach ($k in $obs.Keys) {
    $o = $obs[$k]; $h = $o.home
    $price = if ($h -and $h.listed -and $h.price) { [double]$h.price } else { $null }
    if (-not $price -and $o.asia.Count + $o.early.Count + $o.global.Count -eq 0) { continue }

    if ($o.sec -eq 'materials') {
        $ja = if ($matNames.$($o.en)) { $matNames.$($o.en) } else { $o.en }
        $kind = Get-MaterialGroup $o.en; $rank = 0
    } else {
        $n = Convert-EquipName $o.en; $ja = $n.ja; $kind = $n.part; $rank = $n.rank
    }

    $hist = $spark[$k]
    $wkMed = Get-Median $hist
    $wkLow = if ($hist) { ($hist | Measure-Object -Minimum).Minimum } else { $null }
    $asiaMed = Get-Median $o.asia; $earlyMed = Get-Median $o.early; $globalMed = Get-Median $o.global
    $earlyCh = Get-Median $o.chEarly
    $ch7 = if ($h -and $null -ne $h.change_pct) { [math]::Round($h.change_pct, 1) } else { $null }
    $listings = if ($h) { [int]$h.listings } else { 0 }

    $vsWk = Get-Pct $price $wkMed; $vsAsia = Get-Pct $price $asiaMed
    $vsEarly = Get-Pct $price $earlyMed; $vsGlobal = Get-Pct $price $globalMed

    # Cheap/dear needs one signal and no opposite signal from the other comparison.
    $wkLowSig = $null -ne $vsWk -and $vsWk -le -15; $wkHighSig = $null -ne $vsWk -and $vsWk -ge 20
    $asLowSig = $null -ne $vsAsia -and $vsAsia -le -20; $asHighSig = $null -ne $vsAsia -and $vsAsia -ge 25
    $cheap = ($wkLowSig -or $asLowSig) -and -not ($wkHighSig -or $asHighSig)
    $dear  = ($wkHighSig -or $asHighSig) -and -not ($wkLowSig -or $asLowSig)
    $rise  = ($null -ne $earlyCh -and $earlyCh -ge 10 -and ($null -eq $ch7 -or $ch7 -lt $earlyCh - 10))
    $fall  = ($null -ne $earlyCh -and $earlyCh -le -10 -and ($null -eq $ch7 -or $ch7 -gt $earlyCh + 10))

    $verdict = if (-not $price) { '出品なし' }
               elseif ($cheap -and -not $fall) { '買い時' }
               elseif ($dear -and -not $rise) { '売り時' }
               elseif ($rise) { '上がりそう' }
               elseif ($fall) { '下がりそう' }
               else { '様子見' }

    $why = @()
    if ($null -ne $vsWk -and [math]::Abs($vsWk) -ge 15) { $why += ('1週間の中央値より{0}%{1}' -f [math]::Abs($vsWk), $(if ($vsWk -lt 0) { '安い' } else { '高い' })) }
    if ($null -ne $vsAsia -and [math]::Abs($vsAsia) -ge 20) { $why += ('アジアの他鯖より{0}%{1}' -f [math]::Abs($vsAsia), $(if ($vsAsia -lt 0) { '安い' } else { '高い' })) }
    if ($rise -or $fall) { $why += ('アーリー鯖で1週間{0}{1}%' -f $(if ($earlyCh -gt 0) { '+' } else { '' }), [math]::Round($earlyCh, 1)) }
    if ($price -and $listings -lt 3) { $why += '出品が少なく参考程度' }

    [pscustomobject][ordered]@{
        key = $k; name = $ja; name_en = $o.en
        section = @{ weapons = '製作武器'; accessories = '製作装飾品'; materials = '素材' }[$o.sec]
        kind = $kind; tier = $rank; mine = $(if (Test-Mine $o.sec $o.en) { '○' } else { '' })
        price = Round-Price $price; listings = $listings
        ch24 = $(if ($null -ne $ch24[$k]) { [math]::Round($ch24[$k], 1) } else { $null }); ch7 = $ch7
        wk_med = Round-Price $wkMed; wk_low = Round-Price $wkLow
        asia_med = Round-Price $asiaMed; early_med = Round-Price $earlyMed; global_med = Round-Price $globalMed
        asia_n = $o.asia.Count; early_n = $o.early.Count; global_n = $o.global.Count
        early_ch7 = $(if ($null -ne $earlyCh) { [math]::Round($earlyCh, 1) } else { $null })
        global_ch7 = $(if ($o.chGlobal.Count) { [math]::Round((Get-Median $o.chGlobal), 1) } else { $null })
        vs_wk = $vsWk; vs_asia = $vsAsia; vs_early = $vsEarly; vs_global = $vsGlobal
        verdict = $verdict; reason = ($why -join ' / ')
        spark = $(if ($hist) { ($hist | ForEach-Object { [long]$_ }) -join ',' } else { '' })
        captured_at = $capturedAt
    }
}
$rows = @($rows | Sort-Object { $_.section }, { $_.kind }, { $_.tier }, { $_.name })

# --- Craft or buy (home server) ----------------------------------------------------------
$c = Get-Api "crafts?server=$HomeServer"
$crafts = foreach ($t in $c.targets) {
    if ($t.category -notin 'Weapon', 'Accessory') { continue }
    $n = Convert-EquipName $t.name
    $cost = [double]$t.cost_market
    $mkt = if ($t.market_price -gt 0) { [double]$t.market_price } else { $null }
    $gap = Get-Pct $mkt $cost
    $v = if (-not $mkt) { '作るしかない' } elseif ($gap -ge 5) { '作る' } elseif ($gap -le -5) { '買う' } else { 'ほぼ同じ' }
    [pscustomobject][ordered]@{
        key = [string]$t.target_key; name = $n.ja; name_en = $t.name
        section = $(if ($t.category -eq 'Weapon') { '製作武器' } else { '製作装飾品' })
        mine = $(if ($t.name -match 'Longsword|Guard| Ring$|Necklace') { '○' } else { '' })
        cost = Round-Price $cost; price = Round-Price $mkt; listings = [int]$t.listings
        gap = $gap; verdict = $v; captured_at = $c.captured_at
    }
}
$crafts = @($crafts | Sort-Object { $_.section }, { -[double]$(if ($null -ne $_.gap) { $_.gap } else { 999 }) })

# --- Write -------------------------------------------------------------------------------
$utf8 = New-Object System.Text.UTF8Encoding($false)
$meta = [ordered]@{ captured_at = $capturedAt; home = $HomeServer; asia_servers = $groupCount.asia; early_servers = $groupCount.early; global_servers = $groupCount.global }
[IO.File]::WriteAllText((Join-Path $outDir 'items.json'), (@{ meta = $meta; rows = $rows } | ConvertTo-Json -Depth 5 -Compress), $utf8)
[IO.File]::WriteAllText((Join-Path $outDir 'crafts.json'), (@{ rows = $crafts } | ConvertTo-Json -Depth 5 -Compress), $utf8)

# --- Short summary (keep it small: this is what Claude reads) -----------------------------
"captured_at: $capturedAt  servers: asia=$($groupCount.asia) early=$($groupCount.early) global=$($groupCount.global)  rows=$($rows.Count) crafts=$($crafts.Count)"
foreach ($sec in '製作武器', '製作装飾品', '素材') {
    $s = @($rows | Where-Object { $_.section -eq $sec })
    "[$sec] " + (($s | Group-Object verdict | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')
    $s | Where-Object { $_.verdict -in '買い時', '売り時', '上がりそう', '下がりそう' -and $_.mine } |
        Sort-Object { $_.verdict } | Select-Object -First 8 |
        ForEach-Object { "  {0} {1}: {2:N0} ({3})" -f $_.verdict, $_.name, $_.price, $_.reason }
}
"[作るか買うか(自分の物)] " + (($crafts | Where-Object { $_.mine } | ForEach-Object { "$($_.name)=$($_.verdict)" }) -join ', ')
