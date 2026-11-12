param([Parameter(Mandatory=$true)][string]$SourceDirectory,[Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference='Stop'
function HexColor($color) { $n=[int64]$color; '#{0:X2}{1:X2}{2:X2}' -f ($n -band 255),(($n -shr 8) -band 255),(($n -shr 16) -band 255) }
$excel=New-Object -ComObject Excel.Application
$excel.Visible=$false; $excel.DisplayAlerts=$false; $excel.AskToUpdateLinks=$false; $excel.AutomationSecurity=3
try {
  foreach($spec in @(@('heat','A热量统计热源版26.xls',12,19,22),@('electricity','耗电统计26(2).xls',13,32,47),@('water','耗水统计26.xlsx',13,32,39))) {
    $book=$null
    try {
      $book=$excel.Workbooks.Open((Join-Path $SourceDirectory $spec[1]),0,$true)
      $sheet=@($book.Worksheets | Where-Object {$_.Name.StartsWith('各站')})[0]
      $styles=[ordered]@{}
      $merges=[ordered]@{}; $widths=[ordered]@{}
      $header=[int]$spec[2]; $daily=[int]$spec[3]; $columns=[int]$spec[4]
      foreach($r in (0..($header-1))+@($header,$daily)) {
        for($c=0;$c -lt $columns;$c++) {
          $cell=$sheet.Cells.Item($r+1,$c+1)
          $key=if($r -lt $header){"h${r}_$c"}elseif($r -eq $header){"b$c"}else{"d$c"}
          $styles[$key]=[ordered]@{bg=(HexColor $cell.Interior.Color);fg=(HexColor $cell.Font.Color);bold=[bool]$cell.Font.Bold;size=[double]$cell.Font.Size}
          if($r -eq 0){$widths["$c"]=[math]::Round([double]$sheet.Columns.Item($c+1).Width*4/3,1)}
          if($r -lt $header -and $cell.MergeCells){$area=$cell.MergeArea;$mr=[int]$area.Row-1;$mc=[int]$area.Column-1;if($mr+$area.Rows.Count -le $header -and $mc+$area.Columns.Count -le $columns){$merges["${mr}_$mc"]=[ordered]@{r=$mr;c=$mc;rs=[int]$area.Rows.Count;cs=[int]$area.Columns.Count}};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($area)}
          [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($cell)
        }
      }
      $styles | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory ($spec[0]+'.styles.json')) -Encoding utf8
      [ordered]@{merges=@($merges.Values);widths=$widths} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputDirectory ($spec[0]+'.layout.json')) -Encoding utf8
      Write-Output "$($spec[0]): $($styles.Count) source cell styles extracted read-only"
    } finally { if($null -ne $book){$book.Close($false);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book)} }
  }
} finally { $excel.Quit();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel);[GC]::Collect();[GC]::WaitForPendingFinalizers() }
