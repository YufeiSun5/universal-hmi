param([Parameter(Mandatory=$true)][string[]]$Paths, [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
$excel.AskToUpdateLinks = $false
$excel.AutomationSecurity = 3
try {
  foreach ($sourcePath in $Paths) {
    $book = $null
    try {
      $book = $excel.Workbooks.Open($sourcePath, 0, $true)
      $summary = @()
      $sheets = @()
      foreach ($sheet in $book.Sheets) {
        if ($sheet.Type -ne -4167) {
          $summary += [ordered]@{name=$sheet.Name;type=$sheet.Type}
          continue
        }
        $range = $sheet.UsedRange
        $rowCount = $range.Rows.Count
        $colCount = $range.Columns.Count
        if ($rowCount -gt 2000 -or $colCount -gt 500) { throw "Unexpected used range: $($sheet.Name) $rowCount x $colCount" }
        $values = $range.Value2
        $formulas = $range.Formula
        $cells = [System.Collections.Generic.List[object]]::new()
        $headers = [System.Collections.Generic.List[object]]::new()
        $formulaCount = 0
        $crossSheet = [System.Collections.Generic.HashSet[string]]::new()
        $functions = [System.Collections.Generic.HashSet[string]]::new()
        for ($r=1; $r -le $rowCount; $r++) {
          for ($c=1; $c -le $colCount; $c++) {
            $v = if ($values -is [array]) { $values.GetValue($r,$c) } else { $values }
            $f = if ($formulas -is [array]) { $formulas.GetValue($r,$c) } else { $formulas }
            if ($null -eq $v -and $null -eq $f) { continue }
            $cell = [ordered]@{r=$r+$range.Row-2;c=$c+$range.Column-2;v=$v}
            if ($f -is [string] -and $f.StartsWith('=')) {
              $cell.f = $f
              $formulaCount++
              if ($f.Contains('!')) { [void]$crossSheet.Add($f) }
              foreach ($m in [regex]::Matches($f, '([A-Z][A-Z0-9._]*)\(')) { [void]$functions.Add($m.Groups[1].Value) }
            }
            $cells.Add($cell)
            if ($r -le 8) { $headers.Add($cell) }
          }
        }
        $sheets += [ordered]@{name=$sheet.Name;rows=$rowCount;columns=$colCount;cells=$cells}
        $summary += [ordered]@{name=$sheet.Name;type=$sheet.Type;rows=$rowCount;columns=$colCount;charts=$sheet.ChartObjects().Count;formulas=$formulaCount;functions=@($functions);crossSheetSamples=@($crossSheet | Select-Object -First 8);header=$headers}
      }
      $name = [IO.Path]::GetFileNameWithoutExtension($sourcePath)
      [ordered]@{source=[IO.Path]::GetFileName($sourcePath);sheets=$sheets} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$name.cells.json") -Encoding utf8
      [ordered]@{source=[IO.Path]::GetFileName($sourcePath);sheets=$summary} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath (Join-Path $OutputDirectory "$name.summary.json") -Encoding utf8
      Write-Output "$name inspected: $($summary.Count) sheets"
    } finally {
      if ($null -ne $book) { $book.Close($false); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book) }
    }
  }
} finally {
  $excel.Quit()
  [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
}
