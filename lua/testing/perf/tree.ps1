# testing.perf.tree (Windows): one JSON line per interval with every descendant of -Root (itself and its own
# descendants left out), until -Root is gone or stdin closes. Read by lua/testing/perf/tree.lua.
#   { "procs": [ { "pid", "ppid", "name", "ws", "peak", "cpu", "cmd" } ] }   ws/peak in bytes, cpu in seconds
param([int]$Root, [int]$IntervalMs = 500)
$ErrorActionPreference = 'SilentlyContinue'
$props = 'ProcessId', 'ParentProcessId', 'Name', 'WorkingSetSize', 'PeakWorkingSetSize', 'KernelModeTime', 'UserModeTime', 'CommandLine'
while ($true) {
  $all = @(Get-CimInstance Win32_Process -Property $props)
  if (-not ($all | Where-Object { $_.ProcessId -eq $Root })) { break }
  $kids = @{}
  foreach ($p in $all) {
    $k = [int]$p.ParentProcessId
    if (-not $kids.ContainsKey($k)) { $kids[$k] = New-Object System.Collections.ArrayList }
    [void]$kids[$k].Add($p)
  }
  $out = New-Object System.Collections.ArrayList
  $queue = New-Object System.Collections.Queue
  $seen = @{ $Root = $true }
  $queue.Enqueue($Root)
  while ($queue.Count -gt 0) {
    $parent = [int]$queue.Dequeue()
    if (-not $kids.ContainsKey($parent)) { continue }
    foreach ($c in $kids[$parent]) {
      $cpid = [int]$c.ProcessId
      if ($cpid -eq $PID -or $seen.ContainsKey($cpid)) { continue }
      $seen[$cpid] = $true
      $cmd = [string]$c.CommandLine
      if ($cmd.Length -gt 300) { $cmd = $cmd.Substring(0, 300) }
      [void]$out.Add([ordered]@{
          pid  = $cpid
          ppid = $parent
          name = [string]$c.Name
          ws   = [int64]$c.WorkingSetSize
          peak = [int64]$c.PeakWorkingSetSize * 1024
          cpu  = ([double]$c.KernelModeTime + [double]$c.UserModeTime) / 1e7
          cmd  = $cmd
        })
      $queue.Enqueue($cpid)
    }
  }
  $line = ConvertTo-Json -Compress -Depth 4 @{ procs = @($out) }
  try { [Console]::Out.WriteLine($line); [Console]::Out.Flush() } catch { break }
  Start-Sleep -Milliseconds $IntervalMs
}
