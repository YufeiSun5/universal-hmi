# Cosmetic startup UI only. It owns no project, network or database resources.
# A separate STA message loop keeps animation responsive during native startup.
function Start-HmiStartupWindow([string]$ApplicationPath,[string]$View) {
  if(-not ('UniversalHmi.StartupWindow' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading;
using System.Windows.Forms;
namespace UniversalHmi {
  public sealed class StartupWindow : Form {
    static StartupWindow current;
    static Thread ui;
    static volatile string phase = "正在准备工作空间";
    static volatile bool closing;
    static readonly object gate = new object();
    readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    readonly System.Diagnostics.Stopwatch elapsed = System.Diagnostics.Stopwatch.StartNew();
    readonly Font brand = new Font("Segoe UI",24,FontStyle.Bold);
    readonly Font heading = new Font("Microsoft YaHei UI",12,FontStyle.Bold);
    readonly Font small = new Font("Microsoft YaHei UI",9);
    readonly Font caption = new Font("Segoe UI",9);
    readonly string mode;
    Image logo;
    public static void Open(string iconPath,string view) {
      lock(gate) {
        if(ui != null) return;
        closing=false; phase="正在准备工作空间";
        var ready=new ManualResetEvent(false);
        ui=new Thread(delegate() {
          try {
            Application.EnableVisualStyles();
            using(var form=new StartupWindow(iconPath,view)) {
              current=form; form.Shown += delegate { ready.Set(); };
              Application.Run(form);
            }
          } catch { /* Presentation failure must not terminate project startup. */ }
          finally { current=null; ready.Set(); }
        });
        ui.IsBackground=true; ui.SetApartmentState(ApartmentState.STA); ui.Start();
        ready.WaitOne(3000);
      }
    }
    public static void Update(string text) { phase=text; }
    public static void Finish() {
      lock(gate) {
        closing=true;
        if(ui!=null) { ui.Join(1500); ui=null; }
      }
    }
    // Captures only this application-owned surface for visual regression checks.
    public static void Snapshot(string path) {
      var form=current;
      if(form==null || !form.IsHandleCreated) throw new InvalidOperationException("Startup window is not ready");
      form.Invoke(new Action(delegate {
        using(var bitmap=new Bitmap(form.ClientSize.Width,form.ClientSize.Height)) {
          form.DrawToBitmap(bitmap,form.ClientRectangle);
          bitmap.Save(path,System.Drawing.Imaging.ImageFormat.Png);
        }
      }));
    }
    StartupWindow(string iconPath,string view) {
      mode=view=="developer" ? "开发工作台" : "运行监控";
      Text="Universal HMI · 正在启动";
      FormBorderStyle=FormBorderStyle.None; ControlBox=false; ShowInTaskbar=false;
      StartPosition=FormStartPosition.CenterScreen;
      AutoScaleMode=AutoScaleMode.Dpi; ClientSize=new Size(540,292);
      BackColor=Color.FromArgb(247,250,253);
      SetStyle(ControlStyles.UserPaint|ControlStyles.AllPaintingInWmPaint|ControlStyles.OptimizedDoubleBuffer,true);
      try { using(var icon=Icon.ExtractAssociatedIcon(iconPath)) { logo=icon.ToBitmap(); } } catch { }
      timer.Interval=33;
      timer.Tick += delegate { if(closing) Close(); else Invalidate(); };
      FormClosing += delegate(object sender,FormClosingEventArgs e) { if(!closing) e.Cancel=true; };
      timer.Start();
    }
    protected override CreateParams CreateParams {
      get { var p=base.CreateParams; p.ClassStyle|=0x20000; return p; }
    }
    protected override void OnPaint(PaintEventArgs e) {
      base.OnPaint(e);
      var g=e.Graphics; g.SmoothingMode=SmoothingMode.AntiAlias;
      g.TextRenderingHint=System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
      float sx=ClientSize.Width/540f,sy=ClientSize.Height/292f; g.ScaleTransform(sx,sy);
      using(var wash=new LinearGradientBrush(new Rectangle(0,0,540,292),Color.White,Color.FromArgb(239,247,251),25f)) g.FillRectangle(wash,0,0,540,292);
      using(var glow=new SolidBrush(Color.FromArgb(13,22,153,173))) g.FillEllipse(glow,366,-112,270,270);
      if(logo!=null) g.DrawImage(logo,32,34,58,58);
      else using(var pen=new Pen(Color.FromArgb(12,151,171),4)) { g.DrawEllipse(pen,38,40,44,44); g.DrawLine(pen,48,70,60,51); g.DrawLine(pen,60,51,74,70); }
      using(var ink=new SolidBrush(Color.FromArgb(28,49,72))) g.DrawString("Universal HMI",brand,ink,101,31, StringFormat.GenericTypographic);
      using(var muted=new SolidBrush(Color.FromArgb(101,123,145))) g.DrawString("智慧供热  /  "+mode,small,muted,105,76);
      using(var line=new Pen(Color.FromArgb(226,234,241))) g.DrawLine(line,32,119,508,119);
      float angle=(float)(elapsed.Elapsed.TotalMilliseconds*.16%360);
      using(var track=new Pen(Color.FromArgb(223,235,241),3)) g.DrawEllipse(track,35,151,25,25);
      using(var arc=new Pen(Color.FromArgb(8,155,175),3)) { arc.StartCap=LineCap.Round; arc.EndCap=LineCap.Round; g.DrawArc(arc,35,151,25,25,angle,105); }
      using(var ink=new SolidBrush(Color.FromArgb(38,61,82))) g.DrawString(phase,heading,ink,76,150);
      using(var muted=new SolidBrush(Color.FromArgb(113,133,152))) g.DrawString("首次启动或升级时可能需要稍长时间，请稍候。",small,muted,76,182);
      using(var track=new SolidBrush(Color.FromArgb(224,234,241))) g.FillRectangle(track,32,231,476,3);
      float x=32+(float)((Math.Sin(elapsed.Elapsed.TotalMilliseconds/900.0)+1)*.5)*350;
      using(var pulse=new LinearGradientBrush(new RectangleF(x,231,126,3),Color.FromArgb(25,190,198),Color.FromArgb(63,130,205),0f)) g.FillRectangle(pulse,x,231,126,3);
      using(var muted=new SolidBrush(Color.FromArgb(126,144,161))) {
        g.DrawString("正在为您连接实时监控",small,muted,32,252);
        var seconds=((int)elapsed.Elapsed.TotalSeconds).ToString()+" s";
        g.DrawString(seconds,caption,muted,508-g.MeasureString(seconds,caption).Width,254);
      }
      using(var border=new Pen(Color.FromArgb(214,226,236))) g.DrawRectangle(border,0,0,539,291);
    }
    protected override void Dispose(bool disposing) {
      if(disposing) { timer.Dispose(); brand.Dispose(); heading.Dispose(); small.Dispose(); caption.Dispose(); if(logo!=null) logo.Dispose(); }
      base.Dispose(disposing);
    }
  }
}
'@
  }
  [UniversalHmi.StartupWindow]::Open($ApplicationPath,$View)
}
function Update-HmiStartupWindow([string]$Text) {
  if('UniversalHmi.StartupWindow' -as [type]) { [UniversalHmi.StartupWindow]::Update($Text) }
}
function Close-HmiStartupWindow {
  if('UniversalHmi.StartupWindow' -as [type]) { [UniversalHmi.StartupWindow]::Finish() }
}
