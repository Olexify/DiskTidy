# DiskTidy - disk map + safe cleanup + RAM trim. Built-in Windows only: PowerShell 5.1 + WPF + inline C#.
# Run: DiskTidy.cmd    Self-check: powershell -File DiskTidy.ps1 -SelfTest
param([switch]$SelfTest, [string]$ScanPath = 'C:\', [string]$Theme, [string]$Shot, [string]$Tab)
$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

namespace DiskTidy {
  public class Node {
    public string Name; public string Path; public long Size; public long Files;
    public bool IsDir; public bool IsGroup; public Node Parent;
    public List<Node> Kids = new List<Node>();
  }

  public static class Fmt {
    public static string Size(long b) {
      if (b >= 1L << 30) return (b / 1073741824.0).ToString("0.00") + " GB";
      if (b >= 1L << 20) return (b / 1048576.0).ToString("0.0") + " MB";
      if (b >= 1024) return (b / 1024.0).ToString("0") + " KB";
      return b + " B";
    }
  }

  public static class Shell {
    [DllImport("shell32.dll")] static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);
    // Own taskbar identity, so Windows shows our window icon instead of grouping us under PowerShell.
    public static void SetAppId(string id) { try { SetCurrentProcessExplicitAppUserModelID(id); } catch { } }
  }

  public static class Scanner {
    public static long Files, Bytes; public static volatile bool Cancel;
    const int KeepFiles = 40; // per folder; the rest are merged into one "[N smaller files]" block to save RAM
    // Use at most half the CPU cores so the PC stays responsive while scanning.
    static readonly ParallelOptions Gentle = new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, Environment.ProcessorCount / 2) };

    public static Task<Node> Start(string root) {
      Files = 0; Bytes = 0; Cancel = false;
      return Task.Run(() => { Node n = new Node(); n.Name = root; n.Path = root; n.IsDir = true; Fill(n, 0); return n; });
    }

    static void Fill(Node n, int depth) {
      if (Cancel) return;
      List<Node> dirs = new List<Node>(), files = new List<Node>();
      try {
        foreach (FileSystemInfo e in new DirectoryInfo(n.Path).EnumerateFileSystemInfos()) {
          if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue; // junctions/symlinks: never followed, no double counting
          Node k = new Node(); k.Name = e.Name; k.Path = e.FullName; k.Parent = n;
          if (e is DirectoryInfo) { k.IsDir = true; dirs.Add(k); }
          else { k.Size = ((FileInfo)e).Length; k.Files = 1; files.Add(k); Interlocked.Increment(ref Files); Interlocked.Add(ref Bytes, k.Size); }
        }
      } catch { } // access denied: keep what we got
      if (depth < 2) Parallel.ForEach(dirs, Gentle, d => Fill(d, depth + 1));
      else foreach (Node d in dirs) Fill(d, depth + 1);

      long size = 0, count = files.Count;
      foreach (Node d in dirs) { size += d.Size; count += d.Files; }
      foreach (Node f in files) size += f.Size;
      files.Sort(BySize);
      List<Node> kids = new List<Node>(dirs);
      if (files.Count > KeepFiles + 1) {
        Node g = new Node(); g.IsGroup = true; g.Parent = n; g.Path = n.Path;
        for (int i = KeepFiles; i < files.Count; i++) g.Size += files[i].Size;
        g.Files = files.Count - KeepFiles; g.Name = "[" + g.Files + " smaller files]";
        files.RemoveRange(KeepFiles, files.Count - KeepFiles);
        kids.Add(g);
      }
      kids.AddRange(files); kids.Sort(BySize);
      n.Kids = kids; n.Size = size; n.Files = count;
    }
    static int BySize(Node a, Node b) { return b.Size.CompareTo(a.Size); }
  }

  public static class Treemap {
    // Squarified treemap. v sorted descending, all > 0. Returns x,y,w,h per value.
    public static double[] Layout(double[] v, double x, double y, double w, double h) {
      int n = v.Length; double[] r = new double[n * 4];
      double total = 0; foreach (double d in v) total += d;
      if (total <= 0 || w <= 0 || h <= 0) return r;
      double[] a = new double[n]; double sc = w * h / total;
      for (int i = 0; i < n; i++) a[i] = v[i] * sc;
      int s = 0;
      while (s < n) {
        double side = Math.Min(w, h); if (side <= 0) break;
        int e = s; double sum = 0, worst = double.MaxValue;
        while (e < n) {
          double ns = sum + a[e], wv = Worst(a, s, e, ns, side);
          if (e > s && wv > worst) break;
          sum = ns; worst = wv; e++;
        }
        if (sum <= 0) break;
        double t = sum / side;
        if (w >= h) { double cy = y; for (int i = s; i < e; i++) { double hh = a[i] / t; Set(r, i, x, cy, t, hh); cy += hh; } x += t; w -= t; }
        else        { double cx = x; for (int i = s; i < e; i++) { double ww = a[i] / t; Set(r, i, cx, y, ww, t); cx += ww; } y += t; h -= t; }
        s = e;
      }
      return r;
    }
    static double Worst(double[] a, int s, int e, double sum, double side) {
      double mx = 0, mn = double.MaxValue;
      for (int i = s; i <= e; i++) { if (a[i] > mx) mx = a[i]; if (a[i] < mn) mn = a[i]; }
      if (mn <= 0) return double.MaxValue;
      double s2 = sum * sum, q = side * side;
      return Math.Max(q * mx / s2, s2 / (q * mn));
    }
    static void Set(double[] r, int i, double x, double y, double w, double h) { r[i*4] = x; r[i*4+1] = y; r[i*4+2] = w; r[i*4+3] = h; }
  }

  public class CleanItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void On(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    public string Name { get; set; }
    public string Explanation { get; set; }
    public string Safety { get; set; }
    public string[] Paths { get; set; }
    public bool PerPath { get; set; }       // one tree entry per path (browser profiles, app caches) instead of the folder's contents
    public double MinAgeHours { get; set; }
    public bool NeedsAdmin { get; set; }
    public string[] KeepNames { get; set; } // top entries left unticked by default ("name" or "prefix*")
    public string[] Notes { get; set; }     // "name|note" or "prefix*|note"
    public string Where { get { return Paths == null ? "" : Paths.Length == 1 ? Paths[0] : Paths.Length + " locations, expand to see them"; } }
    bool en = true; public bool Enabled { get { return en; } set { en = value; On("Enabled"); } }
    bool chk; public bool Checked { get { return chk; } set { chk = value; On("Checked"); } }
    long size = -1; public long Size { get { return size; } set { size = value; On("Size"); On("SizeText"); } }
    public string SizeText { get { return size < 0 ? "measuring..." : Fmt.Size(size); } }
    string status = ""; public string Status { get { return status; } set { status = value; On("Status"); } }
    double lh = 240; public double ListHeight { get { return lh; } set { lh = value; On("ListHeight"); } }
    List<SubItem> subs = new List<SubItem>();
    public List<SubItem> Subs { get { return subs; } set { subs = value; On("Subs"); On("HasSubs"); On("SubsHeader"); } }
    public bool HasSubs { get { return subs.Count > 0; } }
    public string SubsHeader { get { return "Choose what to delete  (" + subs.Count + " entries)"; } }
    public long SelectedSize { get { if (!chk || !en) return 0; long s = 0; foreach (SubItem x in subs) s += x.SelectedBytes(); return s; } }
  }

  public enum Kind { Folder, Group, Loose, File, Placeholder }

  // One line in the "Choose what to delete" tree. Children load when expanded; ticks flow down and up (tri-state).
  public class SubItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void On(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    public string Name { get; set; }
    public string Note { get; set; }
    public string Key { get; set; }
    public string Open { get; set; }      // what "Open in Explorer" shows
    public string[] Paths { get; set; }
    public bool KeepRoot { get; set; }    // empty the folder but keep it (cache folders apps expect to exist)
    public Kind Kind { get; set; }
    public SubItem Parent;
    public bool IsPlaceholder { get { return Kind == Kind.Placeholder; } }
    long size; public long Size { get { return size; } set { size = value; On("Size"); On("SizeText"); } }
    public string SizeText { get { return IsPlaceholder ? "" : Fmt.Size(size); } }

    bool? chk = true;
    public bool? Checked { get { return chk; } set { Set(value, true, true); } }
    public void Set(bool? v, bool down, bool up) {
      if (v == chk) return;
      chk = v; On("Checked");
      if (down && v.HasValue && Loaded) foreach (SubItem k in kids) k.Set(v, true, false);
      if (up && Parent != null) Parent.Recompute();
    }
    void Recompute() {
      bool? s = null; bool first = true;
      foreach (SubItem k in kids) { if (k.IsPlaceholder) continue; if (first) { s = k.chk; first = false; } else if (s != k.chk) { s = null; break; } }
      if (!first) Set(s, false, true);
    }

    List<SubItem> kids;
    public List<SubItem> Kids { get { return kids; } }
    public bool Loaded;
    bool loading, exp;
    public bool IsExpanded {
      get { return exp; }
      set { exp = value; On("IsExpanded"); if (value && !Loaded && !loading && kids != null) { loading = true; Task.Run(() => Cleaner.LoadKids(this)); } }
    }
    public void SetKids(List<SubItem> k, bool loaded) { kids = k; Loaded = loaded; On("Kids"); }
    public long SelectedBytes() {
      if (chk == true) return size; if (chk == false) return 0;
      long s = 0; if (kids != null) foreach (SubItem k in kids) s += k.SelectedBytes(); return s;
    }
  }

  public static class Cleaner {
    public static long Measure(string p) {
      if (File.Exists(p)) { try { return new FileInfo(p).Length; } catch { return 0; } }
      long s = 0;
      try {
        foreach (FileSystemInfo e in new DirectoryInfo(p).EnumerateFileSystemInfos()) {
          if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
          if (e is DirectoryInfo) s += Measure(e.FullName); else s += ((FileInfo)e).Length;
        }
      } catch { }
      return s;
    }

    static bool Match(string name, string pat) {
      return pat.EndsWith("*") ? name.StartsWith(pat.Substring(0, pat.Length - 1), StringComparison.OrdinalIgnoreCase)
                               : string.Equals(name, pat, StringComparison.OrdinalIgnoreCase);
    }
    static string Lcp(string a, string b) {
      int i = 0; while (i < a.Length && i < b.Length && char.ToLowerInvariant(a[i]) == char.ToLowerInvariant(b[i])) i++;
      return a.Substring(0, i);
    }
    static SubItem Placeholder() { SubItem p = new SubItem(); p.Kind = Kind.Placeholder; p.Name = "loading..."; return p; }
    static SubItem Make(Kind k, string name, string key, string[] paths, string open) {
      SubItem s = new SubItem(); s.Kind = k; s.Name = name; s.Key = key; s.Paths = paths; s.Open = open;
      if (k != Kind.File) s.SetKids(new List<SubItem> { Placeholder() }, false);
      long z = 0; foreach (string p in paths) z += Measure(p); s.Size = z;
      return s;
    }
    static SubItem FolderNode(string path, string name) { return Make(Kind.Folder, name + "\\", path, new string[] { path }, path); }
    static void Rules(CleanItem owner, SubItem s, string bare) {
      if (owner == null) return;
      if (owner.KeepNames != null) foreach (string k in owner.KeepNames) if (Match(bare, k)) s.Checked = false;
      if (owner.Notes != null) foreach (string n in owner.Notes) { int i = n.IndexOf('|'); if (i > 0 && Match(bare, n.Substring(0, i))) { s.Note = n.Substring(i + 1); break; } }
    }

    // Contents of one folder: sub-folders (runs of 4+ look-alike names become one group), then loose files.
    static List<SubItem> Build(string dir, CleanItem owner) {
      List<DirectoryInfo> dirs = new List<DirectoryInfo>(); List<FileInfo> files = new List<FileInfo>();
      try {
        foreach (FileSystemInfo e in new DirectoryInfo(dir).EnumerateFileSystemInfos()) {
          if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
          if (e is DirectoryInfo) dirs.Add((DirectoryInfo)e); else files.Add((FileInfo)e);
        }
      } catch { }
      dirs.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
      List<SubItem> r = new List<SubItem>();
      int i = 0;
      while (i < dirs.Count) {
        string pre = dirs[i].Name; int j = i + 1;
        while (j < dirs.Count) { string p2 = Lcp(pre, dirs[j].Name); if (p2.Length < 6) break; pre = p2; j++; }
        if (j - i >= 4) {
          string[] ps = new string[j - i]; for (int k = i; k < j; k++) ps[k - i] = dirs[k].FullName;
          SubItem g = Make(Kind.Group, pre + "*   (" + (j - i) + " similar folders)", "group:" + pre, ps, dir);
          Rules(owner, g, pre); r.Add(g);
        } else for (int k = i; k < j; k++) { SubItem f = FolderNode(dirs[k].FullName, dirs[k].Name); Rules(owner, f, dirs[k].Name); r.Add(f); }
        i = j;
      }
      if (files.Count > 3) {
        string[] fs = new string[files.Count]; for (int k = 0; k < files.Count; k++) fs[k] = files[k].FullName;
        r.Add(Make(Kind.Loose, "[" + files.Count + " loose files]", "*loose", fs, dir));
      } else foreach (FileInfo f in files) r.Add(Make(Kind.File, f.Name, f.FullName, new string[] { f.FullName }, f.FullName));
      r.Sort((a, b) => b.Size.CompareTo(a.Size));
      return r;
    }

    public static void LoadKids(SubItem n) {
      List<SubItem> k = new List<SubItem>();
      if (n.Kind == Kind.Folder) k = Build(n.Paths[0], null);
      else if (n.Kind == Kind.Group) { foreach (string p in n.Paths) k.Add(FolderNode(p, Path.GetFileName(p))); }
      else if (n.Kind == Kind.Loose) {
        List<FileInfo> fs = new List<FileInfo>();
        foreach (string p in n.Paths) { try { fs.Add(new FileInfo(p)); } catch { } }
        fs.Sort((a, b) => { long la = a.Exists ? a.Length : 0, lb = b.Exists ? b.Length : 0; return lb.CompareTo(la); });
        int show = Math.Min(fs.Count, 300);
        for (int i = 0; i < show; i++) k.Add(Make(Kind.File, fs[i].Name, fs[i].FullName, new string[] { fs[i].FullName }, fs[i].FullName));
        if (fs.Count > show) {
          string[] rest = new string[fs.Count - show]; for (int i = show; i < fs.Count; i++) rest[i - show] = fs[i].FullName;
          k.Add(Make(Kind.Loose, "[" + rest.Length + " smaller files]", "*rest", rest, n.Open));
        }
      }
      k.Sort((a, b) => b.Size.CompareTo(a.Size));
      bool? c = n.Checked;
      foreach (SubItem x in k) { x.Checked = c ?? true; x.Parent = n; }
      n.SetKids(k, true);
    }

    static List<SubItem> Roots(CleanItem it) {
      if (!it.PerPath && Directory.Exists(it.Paths[0])) return Build(it.Paths[0], it);
      List<SubItem> r = new List<SubItem>();
      foreach (string p in it.Paths) {
        string tail = Path.GetFileName(Path.GetDirectoryName(p)) + "\\" + Path.GetFileName(p);
        SubItem s = File.Exists(p) ? Make(Kind.File, tail, p, new string[] { p }, p) : Make(Kind.Folder, tail + "\\", p, new string[] { p }, p);
        s.KeepRoot = true; r.Add(s);
      }
      r.Sort((a, b) => b.Size.CompareTo(a.Size));
      return r;
    }

    static void Refresh(CleanItem it) {
      Dictionary<string, bool> was = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
      foreach (SubItem s in it.Subs) was[s.Key] = s.Checked == true; // part-ticked counts as unticked after a refresh: never widen a choice
      List<SubItem> fresh = Roots(it); long total = 0;
      foreach (SubItem s in fresh) { bool c; if (was.TryGetValue(s.Key, out c)) s.Checked = c; total += s.Size; }
      it.Subs = fresh; it.Size = total;
    }

    public static Task MeasureAll(IList<CleanItem> items) {
      return Task.Run(() => {
        ThreadPriority was = Thread.CurrentThread.Priority;
        Thread.CurrentThread.Priority = ThreadPriority.BelowNormal; // background sizing must not slow down what you are doing
        try { foreach (CleanItem it in items) Refresh(it); } finally { Thread.CurrentThread.Priority = was; }
      });
    }

    class Result { public long Freed; public int Skipped; }

    public static Task<long> CleanAll(IList<CleanItem> items) {
      return Task.Run(() => {
        long total = 0;
        foreach (CleanItem it in items) {
          if (!it.Checked || !it.Enabled) continue;
          it.Status = "cleaning...";
          Result r = new Result(); DateTime cutoff = DateTime.Now.AddHours(-it.MinAgeHours);
          foreach (SubItem s in it.Subs) CleanNode(s, cutoff, r);
          total += r.Freed;
          it.Status = "Freed " + Fmt.Size(r.Freed) + (r.Skipped > 0 ? " (" + r.Skipped + " files in use or recent, left alone)" : "");
          Refresh(it);
        }
        return total;
      });
    }

    static void CleanNode(SubItem n, DateTime cutoff, Result r) {
      if (n.IsPlaceholder || n.Checked == false) return;
      if (n.Checked == true) { foreach (string p in n.Paths) DeletePath(p, n.KeepRoot, cutoff, r); return; }
      foreach (SubItem k in n.Kids) CleanNode(k, cutoff, r); // part-ticked: only the ticked children
      if (n.Kind == Kind.Folder && !n.KeepRoot) { DirectoryInfo d = new DirectoryInfo(n.Paths[0]); if (d.Exists && !Recent(d, cutoff)) RemoveIfEmpty(d.FullName); }
    }

    static void DeletePath(string p, bool keepRoot, DateTime cutoff, Result r) {
      if (File.Exists(p)) { DelFile(new FileInfo(p), cutoff, r); return; }
      DirectoryInfo d = new DirectoryInfo(p);
      if (!d.Exists || (d.Attributes & FileAttributes.ReparsePoint) != 0) return; // never follow or delete links
      bool recent = Recent(d, cutoff);
      CleanDir(p, cutoff, r);
      if (!keepRoot && !recent) RemoveIfEmpty(p);
    }

    static bool Recent(FileSystemInfo f, DateTime cutoff) { return f.LastWriteTime > cutoff || f.CreationTime > cutoff; }

    static void DelFile(FileInfo f, DateTime cutoff, Result r) {
      if (Recent(f, cutoff)) { r.Skipped++; return; }
      try { long l = f.Length; if (f.IsReadOnly) f.IsReadOnly = false; f.Delete(); r.Freed += l; }
      catch { r.Skipped++; }
    }

    static void RemoveIfEmpty(string dir) {
      try { using (IEnumerator<string> en = Directory.EnumerateFileSystemEntries(dir).GetEnumerator()) { if (!en.MoveNext()) Directory.Delete(dir); } } catch { }
    }

    static void CleanDir(string dir, DateTime cutoff, Result r) {
      List<FileSystemInfo> es = new List<FileSystemInfo>();
      try { foreach (FileSystemInfo e in new DirectoryInfo(dir).EnumerateFileSystemInfos()) es.Add(e); } catch { r.Skipped++; return; }
      foreach (FileSystemInfo e in es) {
        if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
        if (e is DirectoryInfo) {
          bool recentDir = Recent(e, cutoff); // read before cleaning changes it
          CleanDir(e.FullName, cutoff, r);
          if (!recentDir) RemoveIfEmpty(e.FullName);
        } else DelFile((FileInfo)e, cutoff, r);
      }
    }
  }

  public class ProcItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    void On(string p) { PropertyChangedEventHandler h = PropertyChanged; if (h != null) h(this, new PropertyChangedEventArgs(p)); }
    public string Name { get; set; }
    public string Note { get; set; }
    public List<int> Ids = new List<int>();
    public int Count { get { return Ids.Count; } }
    public long Mem;
    public string MemText { get { return Fmt.Size(Mem); } }
    bool chk; public bool Checked { get { return chk; } set { chk = value; On("Checked"); } }
  }

  public static class Ram {
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr h);
    [StructLayout(LayoutKind.Sequential)] class MemStat { public uint Length = 64; public uint Load; public ulong Total, Avail, TotalPage, AvailPage, TotalVirt, AvailVirt, AvailExt; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx([In, Out] MemStat m);
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TokenPriv { public int Count; public long Luid; public int Attr; }
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, int access, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool LookupPrivilegeValue(string sys, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr tok, bool disableAll, ref TokenPriv st, int len, IntPtr prev, IntPtr retLen);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int infoClass, ref int info, int length);

    public static long Avail() { MemStat m = new MemStat(); GlobalMemoryStatusEx(m); return (long)m.Avail; }
    public static long Total() { MemStat m = new MemStat(); GlobalMemoryStatusEx(m); return (long)m.Total; }

    public static List<ProcItem> List() {
      Dictionary<string, ProcItem> d = new Dictionary<string, ProcItem>(StringComparer.OrdinalIgnoreCase);
      foreach (Process p in Process.GetProcesses()) {
        using (p) {
          if (p.Id <= 4) continue;
          long ws; try { ws = p.WorkingSet64; } catch { continue; }
          ProcItem it; if (!d.TryGetValue(p.ProcessName, out it)) { it = new ProcItem(); it.Name = p.ProcessName; d[it.Name] = it; }
          it.Ids.Add(p.Id); it.Mem += ws;
        }
      }
      List<ProcItem> r = new List<ProcItem>(d.Values);
      r.Sort((a, b) => b.Mem.CompareTo(a.Mem));
      return r;
    }

    // Moves idle pages out of each process's working set. Nothing is closed or lost; pages come back on next use.
    public static Task<long> Trim(IList<ProcItem> items) {
      return Task.Run(() => {
        long before = Avail();
        foreach (ProcItem it in items) {
          if (!it.Checked) continue;
          foreach (int id in it.Ids) { try { using (Process p = Process.GetProcessById(id)) EmptyWorkingSet(p.Handle); } catch { } }
        }
        Thread.Sleep(300);
        return Avail() - before;
      });
    }

    // Drops cached file data ("standby list") from RAM, like Mem Reduct. Needs admin.
    public static string PurgeStandby() {
      IntPtr tok;
      if (!OpenProcessToken(Process.GetCurrentProcess().Handle, 0x28, out tok)) return "could not open token";
      try {
        TokenPriv tp = new TokenPriv(); tp.Count = 1; tp.Attr = 2;
        if (!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out tp.Luid)) return "privilege lookup failed";
        if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero) || Marshal.GetLastWin32Error() != 0) return "needs admin";
      } finally { CloseHandle(tok); }
      int cmd = 4; // MemoryPurgeStandbyList
      int st = NtSetSystemInformation(80, ref cmd, 4); // SystemMemoryListInformation
      return st == 0 ? null : "failed (0x" + st.ToString("X8") + ")";
    }
  }
}
'@

# ---------- drive health (read-only; runs in a background runspace) ----------
$collectDrives = {
  foreach ($d in (Get-PhysicalDisk | Sort-Object { [int]$_.DeviceId })) {
    $rc = try { $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { $null } # temperature/wear/errors: needs admin
    $parts = foreach ($p in (Get-Partition -DiskNumber ([int]$d.DeviceId) -ErrorAction SilentlyContinue)) {
      $v = if ($p.DriveLetter -and $p.DriveLetter -ne [char]0) { Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue }
      [pscustomobject]@{ Letter = $(if ($v) { "$($p.DriveLetter):" } else { '' }); Type = [string]$p.Type; Size = [long]$p.Size
        Free = $(if ($v) { [long]$v.SizeRemaining } else { -1 }); Label = $(if ($v) { $v.FileSystemLabel }); FS = $(if ($v) { $v.FileSystem }); IsBoot = [bool]$p.IsBoot }
    }
    [pscustomobject]@{ Number = [int]$d.DeviceId; Name = $d.FriendlyName; Media = [string]$d.MediaType; Bus = [string]$d.BusType; Size = [long]$d.Size
      Health = [string]$d.HealthStatus; Status = ($d.OperationalStatus -join ', '); HasRc = [bool]$rc
      Temp = $(if ($rc) { $rc.Temperature }); TempMax = $(if ($rc) { $rc.TemperatureMax }); Wear = $(if ($rc) { $rc.Wear }); Hours = $(if ($rc) { $rc.PowerOnHours })
      ReadErr = $(if ($rc) { $rc.ReadErrorsUncorrected }); WriteErr = $(if ($rc) { $rc.WriteErrorsUncorrected }); Parts = @($parts) }
  }
}
function Drive-Warnings($d) {
  $w = @()
  if ($d.Health -and $d.Health -ne 'Healthy') { $w += "Windows reports this drive as $($d.Health) ($($d.Status)). Copy your important files off it now, before anything else." }
  if ($d.Wear -ge 80) { $w += "$($d.Wear)% of this SSD's rated life is used. Plan a replacement and keep backups." }
  if ($d.ReadErr -gt 0 -or $d.WriteErr -gt 0) { $w += "The drive reported $($d.ReadErr) read and $($d.WriteErr) write errors it could not fix. That is an early sign of failure: back it up." }
  if ($d.Temp -ge 70) { $w += "Running hot ($($d.Temp) C). Check airflow or the heatsink." }
  $w
}

# ---------- self-check ----------
if ($SelfTest) {
  $dr = @(& $collectDrives)
  if ($dr.Count -lt 1 -or -not $dr[0].Name -or $dr[0].Size -le 0) { throw 'drive list broken' }
  if (@(Drive-Warnings ([pscustomobject]@{ Health = 'Warning'; Status = 'Predictive Failure'; Wear = 91; ReadErr = 2; WriteErr = 0; Temp = 75 })).Count -ne 4) { throw 'drive warnings broken' }
  if (@(Drive-Warnings ([pscustomobject]@{ Health = 'Healthy'; Wear = 3; ReadErr = 0; WriteErr = 0; Temp = 40 })).Count -ne 0) { throw 'false drive warning' }
  if ([math]::Min(1.0, 518 / 930) -ge 0.9) { throw 'usage bar maths' }
  $v = [double[]](6, 6, 4, 3, 2, 2, 1)
  $r = [DiskTidy.Treemap]::Layout($v, 0, 0, 6, 4)
  for ($i = 0; $i -lt $v.Count; $i++) {
    $a = $r[$i*4+2] * $r[$i*4+3]
    if ([math]::Abs($a - $v[$i]) -gt 1e-6) { throw "treemap area $i is $a, want $($v[$i])" }
    if ($r[$i*4] -lt -1e-9 -or $r[$i*4+1] -lt -1e-9 -or $r[$i*4] + $r[$i*4+2] -gt 6 + 1e-6 -or $r[$i*4+1] + $r[$i*4+3] -gt 4 + 1e-6) { throw "treemap rect $i out of bounds" }
  }
  $old = (Get-Date).AddDays(-2)
  function Old($p) { $i = Get-Item -LiteralPath $p -Force; $i.LastWriteTime = $old; $i.CreationTime = $old }
  $t = Join-Path ([IO.Path]::GetTempPath()) ("disktidy-test-" + [guid]::NewGuid())
  $outside = "$t-outside"
  New-Item -ItemType Directory "$t\sub", "$t\claude", "$t\proj\a", "$t\proj\b", $outside -Force | Out-Null
  foreach ($k in 1..5) { New-Item -ItemType Directory "$t\render-assets$k" | Out-Null; 'x' | Set-Content "$t\render-assets$k\f.bin"; Old "$t\render-assets$k\f.bin"; Old "$t\render-assets$k" }
  'x' | Set-Content "$t\old.txt"; 'x' | Set-Content "$t\sub\old2.txt"; 'x' | Set-Content "$t\new.txt"; 'keep' | Set-Content "$outside\precious.txt"
  'k' | Set-Content "$t\claude\cache.bin"; 'a' | Set-Content "$t\proj\a\x.bin"; 'b' | Set-Content "$t\proj\b\x.bin"
  foreach ($f in "$t\old.txt", "$t\sub\old2.txt", "$t\claude\cache.bin", "$t\proj\a\x.bin", "$t\proj\b\x.bin", "$t\sub", "$t\proj\a", "$t\proj\b") { Old $f }
  New-Item -ItemType Junction "$t\link" -Target $outside | Out-Null
  $it = New-Object DiskTidy.CleanItem -Property @{ Name = 't'; Paths = [string[]]@($t); MinAgeHours = 2; Checked = $true; KeepNames = [string[]]@('claude') }
  $all = [DiskTidy.CleanItem[]]@($it)
  [DiskTidy.Cleaner]::MeasureAll($all).Wait()
  $names = @($it.Subs | ForEach-Object Name)
  if ((@($it.Subs | Where-Object { $_.Checked -eq $false }).Name) -ne 'claude\') { throw 'claude should start unticked' }
  if ($names -contains 'link\') { throw 'junction listed' }
  if (-not ($names -like 'render-assets*(5 similar folders)')) { throw "look-alike folders not grouped: $names" }
  $proj = $it.Subs | Where-Object Name -eq 'proj\'
  [DiskTidy.Cleaner]::LoadKids($proj)
  ($proj.Kids | Where-Object Name -eq 'a\').Checked = $false
  if ($null -ne $proj.Checked) { throw 'parent should be part-ticked' }
  $freed = [DiskTidy.Cleaner]::CleanAll($all).Result
  if (-not (Test-Path "$t\claude\cache.bin")) { throw 'unticked folder was deleted' }
  if (-not (Test-Path "$t\proj\a\x.bin")) { throw 'unticked child was deleted' }
  if (Test-Path "$t\proj\b") { throw 'ticked child not deleted' }
  if (Test-Path "$t\render-assets1") { throw 'grouped folders not deleted' }
  if (Test-Path "$t\old.txt") { throw 'old file not deleted' }
  if (-not (Test-Path "$t\new.txt")) { throw 'recent file was deleted' }
  if (-not (Test-Path "$outside\precious.txt")) { throw 'followed a junction!' }
  if ($freed -le 0) { throw 'freed nothing' }
  if (($it.Subs | Where-Object Name -eq 'proj\').Checked -ne $false) { throw 'part-ticked entry must come back unticked after a clean' }
  cmd /c rmdir "$t\link"; Remove-Item $t, $outside -Recurse -Force
  $n = [DiskTidy.Scanner]::Start($PSScriptRoot).Result
  if ($n.Size -le 0 -or $n.Files -lt 1) { throw 'scanner found nothing' }
  $ps = [DiskTidy.Ram]::List()
  if ($ps.Count -lt 5 -or [DiskTidy.Ram]::Avail() -le 0 -or [DiskTidy.Ram]::Avail() -gt [DiskTidy.Ram]::Total()) { throw 'RAM info broken' }
  $me = $ps | Where-Object { $_.Ids -contains $PID }; $me.Checked = $true
  [void][DiskTidy.Ram]::Trim([DiskTidy.ProcItem[]]@($me)).Result # trims only this test process
  'SELFTEST OK'; exit 0
}

[DiskTidy.Shell]::SetAppId('DiskTidy.App')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')

# ---------- settings ----------
$cfgFile = Join-Path $env:APPDATA 'DiskTidy\settings.json'
$cfg = @{ Theme = 'Light'; Zoom = 1.0; AutoScan = $false; MapH = 0; PanelH = 0; ListW = 0; Scroll = 0 }
try { $j = Get-Content $cfgFile -Raw | ConvertFrom-Json; if ($j.Theme) { $cfg.Theme = $j.Theme }; if ($j.Zoom) { $cfg.Zoom = [double]$j.Zoom }; $cfg.AutoScan = [bool]$j.AutoScan
  foreach ($k in 'MapH', 'PanelH', 'ListW', 'Scroll') { if ($j.$k) { $cfg[$k] = [double]$j.$k } } } catch { }
if ($Theme) { $cfg.Theme = $Theme }
if ($Shot) { $cfg.Zoom = 1.0 }
function Save-Cfg { try { New-Item -ItemType Directory (Split-Path $cfgFile) -Force | Out-Null; $cfg | ConvertTo-Json | Set-Content $cfgFile } catch { } }

# ---------- what can be cleaned (Downloads, Recycle Bin, Documents, Desktop, .claude, Docker, projects: never listed) ----------
$L = $env:LOCALAPPDATA; $A = $env:APPDATA; $U = $env:USERPROFILE
$items = New-Object 'System.Collections.Generic.List[DiskTidy.CleanItem]'
function Item($name, $safety, $paths, $explain, [double]$age = 0, [switch]$admin, [string[]]$keep = @(), [string[]]$notes = @()) {
  $p = if ($Shot) { @($paths | ForEach-Object { $_.Replace($env:USERPROFILE, 'C:\Users\you') }) } # screenshots: generic paths, nothing checked on this PC
       else { @(foreach ($x in $paths) { Get-Item -Path $x -Force -ErrorAction SilentlyContinue | ForEach-Object FullName }) }
  if (-not $p) { return }
  $perPath = @($paths).Count -gt 1 -or (@($paths) -match '\*').Count -gt 0
  $i = New-Object DiskTidy.CleanItem -Property @{ Name = $name; Safety = $safety; Paths = [string[]]$p; PerPath = $perPath; Explanation = $explain
    MinAgeHours = $age; NeedsAdmin = [bool]$admin; KeepNames = $keep; Notes = $notes }
  $i.Checked = ($safety -eq 'Safe')
  if ($admin -and -not $isAdmin) { $i.Enabled = $false; $i.Checked = $false; $i.Status = 'Needs admin: click "Restart as admin" below.' }
  $items.Add($i)
}
$chrome = "$L\Google\Chrome\User Data\*"; $edge = "$L\Microsoft\Edge\User Data\*"
$electron = foreach ($app in 'Claude', 'discord', 'Code', 'Cursor', 'Slack', 'obsidian', 'Signal', 'Postman', 'GitHub Desktop', 'Notion', 'Figma') {
  foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache') { "$A\$app\$c" } }

Item 'Your Temp folder' Safe "$L\Temp" 'Scratch space apps use while they work: installer leftovers, render assets, AI tool session files. Apps recreate what they need. Anything touched in the last 2 hours or still open is skipped. Expand it to pick folders; "claude" is unticked by default.' 2 `
  -keep 'claude' -notes 'claude|Claude Code session files (tool outputs, scratchpads of sessions you may reopen). Kept unless you tick it.', 'remotion-*|Remotion render leftovers', 'chrome-devtools-mcp*|chrome-devtools MCP scratch'
Item 'Windows Temp' Safe 'C:\Windows\Temp' 'The same scratch space, used by Windows services and installers. Recent and open files are skipped.' 2 -admin
Item 'Crash dumps' Safe "$L\CrashDumps" 'Memory snapshots saved when an app crashed. Only useful if you send them to that app''s developer.'
Item 'Error reports' Safe "$L\Microsoft\Windows\WER", 'C:\ProgramData\Microsoft\Windows\WER\ReportArchive', 'C:\ProgramData\Microsoft\Windows\WER\ReportQueue' 'Crash reports Windows already sent (or queued) to Microsoft. Some need admin; those are just skipped.'
Item 'Windows memory dumps' Safe 'C:\Windows\MEMORY.DMP', 'C:\Windows\Minidump', 'C:\Windows\LiveKernelReports' 'Snapshots Windows saved after a blue screen or a driver hang. Only needed to debug that crash.' 0 -admin
Item 'Windows servicing logs' Safe 'C:\Windows\Logs\CBS', 'C:\Windows\Logs\DISM' 'Logs from installing Windows updates and features. The log in use is skipped.' 2 -admin
Item 'npm cache' Safe "$L\npm-cache" 'Copies of every npm package you ever downloaded. npm downloads them again when a project needs them; the next install is only slower. node_modules in your projects stay.'
Item 'pip and uv caches' Safe "$L\pip\cache", "$L\uv\cache" 'Downloaded Python packages. Downloaded again when needed. Installed packages and virtual environments stay.'
Item 'Yarn cache' Safe "$L\Yarn\Cache" 'Downloaded Yarn packages. Re-downloaded when needed.'
Item 'Rust and Go download caches' Safe "$U\.cargo\registry\cache", "$L\go-build" 'Downloaded .crate archives and Go build outputs. Fetched or rebuilt on the next build. Toolchains and installed tools stay.'
Item 'JS tooling downloads' Safe "$L\electron\Cache", "$L\electron-builder\Cache", "$L\node-gyp\Cache", "$L\Microsoft\TypeScript" 'Electron binaries, native-module headers and TypeScript type downloads that build tools fetch. Fetched again when needed.'
Item 'GPU shader caches' Safe "$L\NVIDIA\DXCache", "$L\NVIDIA\GLCache", "$L\D3DSCache", "$L\AMD\DxCache" 'Compiled graphics shaders. Games and apps rebuild them; the first launch afterwards may stutter for a moment.'
Item 'Chrome cache' Safe "$chrome\Cache", "$chrome\Code Cache", "$chrome\GPUCache" 'Cached web pages and images for every Chrome profile. Logins, cookies, history, bookmarks and extensions are not touched. Close Chrome first, otherwise open files are skipped.'
Item 'Edge cache' Safe "$edge\Cache", "$edge\Code Cache", "$edge\GPUCache" 'Same as Chrome cache, for Microsoft Edge. Logins and history stay.'
Item 'Desktop app caches' Safe $electron 'Web caches of Claude, Discord, VS Code, Cursor, Obsidian and similar apps. Logins, chats, settings and notes are stored elsewhere and stay. Close an app first to clean all of its cache.'
Item 'Editor leftovers' Safe "$A\Code\CachedData", "$A\Code\CachedExtensionVSIXs", "$A\Code\logs", "$A\Cursor\CachedData", "$A\Cursor\CachedExtensionVSIXs", "$A\Cursor\logs" 'Compiled code of old VS Code / Cursor versions, downloaded extension installers and logs. Extensions and settings stay.'
Item 'Game launcher web caches' Safe "$L\Steam\htmlcache", "$L\EpicGamesLauncher\Saved\webcache*" 'Store pages cached by Steam and Epic. Games, saves and logins stay.'
Item 'Internet cache (Windows)' Safe "$L\Microsoft\Windows\INetCache" 'Web cache used by Windows itself and older apps.'
Item 'Thumbnail cache' Safe "$L\Microsoft\Windows\Explorer\thumbcache_*.db" 'Explorer''s picture previews. Rebuilt as you open folders. Files Explorer has open are skipped.'
Item 'App updater leftovers' Safe "$L\SquirrelTemp", "$L\*-updater" 'Installers that apps downloaded to update themselves. The update is already done; the app downloads again if it needs to.'
Item 'NVIDIA installer leftovers' Safe 'C:\NVIDIA', 'C:\ProgramData\NVIDIA Corporation\Downloader' 'Unpacked graphics-driver installers. The installed driver stays. The second folder needs admin.'
Item 'Windows Update downloads' Safe 'C:\Windows\SoftwareDistribution\Download' 'Installers for updates that are already installed. If an update is still pending, Windows just downloads it again.' 2 -admin
Item 'Delivery Optimization cache' Safe 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache' 'Update pieces Windows keeps to share with other PCs. Not needed.' 0 -admin
Item 'JetBrains caches and logs' Caution "$L\JetBrains\*\caches", "$L\JetBrains\*\index", "$L\JetBrains\*\log" 'IntelliJ / PyCharm / WebStorm indexes. Harmless, but the IDE re-indexes your projects on next open, which takes a few minutes.'
Item 'Gradle and Maven caches' Caution "$U\.gradle\caches", "$U\.m2\repository" 'Java/Android build dependencies. Harmless, but the next build downloads them all again.'
Item 'Playwright browsers' Caution "$L\ms-playwright" 'Browsers that Playwright test tools downloaded. Tests download them again (hundreds of MB) next time.'
Item 'Adobe media cache' Caution "$A\Adobe\Common\Media Cache Files", "$A\Adobe\Common\Media Cache" 'Audio previews After Effects and Premiere build for footage. Big projects re-conform on next open, which is slow.'
Item 'chrome-devtools-mcp browser' Caution "$U\.cache\chrome-devtools-mcp" 'A Chrome copy the chrome-devtools MCP tool downloaded. It downloads it again (a few hundred MB) next time it runs.'
Item 'Hugging Face models' Caution "$U\.cache\huggingface" 'AI models downloaded by Python tools (Whisper, transformers and so on). Harmless to delete, but each tool downloads its model again, which can be gigabytes.'

if ($Shot) { # README screenshot: a typical PC's numbers instead of this one's (and no list of what is installed here)
  $demo = [ordered]@{ 'Your Temp folder' = 6.8GB; 'Windows Temp' = 410MB; 'Crash dumps' = 1.2GB; 'npm cache' = 2.9GB; 'pip and uv caches' = 870MB
    'GPU shader caches' = 640MB; 'Chrome cache' = 1.1GB; 'Desktop app caches' = 920MB; 'Windows Update downloads' = 3.4GB; 'Gradle and Maven caches' = 2.2GB }
  $keepItems = @($items | Where-Object { $demo.Contains($_.Name) }); $items.Clear()
  foreach ($i in $keepItems) { $i.Size = [long]$demo[$i.Name]; $items.Add($i) }
  $items[0].Explanation = 'Scratch space apps use while they work: installer leftovers, render files, session data. Apps recreate what they need. Anything touched in the last 2 hours or still open is skipped. Expand it to pick folders.'
  function DemoSub($name, $size, $note, $checked = $true) {
    $s = New-Object DiskTidy.SubItem -Property @{ Name = $name; Size = [long]$size; Note = $note; Kind = 'Folder'; Paths = [string[]]@('x'); Key = $name }; $s.Checked = $checked; $s }
  $items[0].Subs = [Collections.Generic.List[DiskTidy.SubItem]]@(
    (DemoSub 'render-assets-*   (48 similar folders)' 2.1GB 'Video render leftovers'),
    (DemoSub 'app-sessions\' 1.9GB 'Session files of an app you may reopen. Kept unless you tick it.' $false),
    (DemoSub '[812 loose files]' 1.3GB ''), (DemoSub 'pip-unpack-*   (17 similar folders)' 690MB ''),
    (DemoSub 'browser-test-profile\' 520MB 'Test browser scratch'), (DemoSub 'NVIDIA Corporation\' 310MB ''))
}
# Made-up drive for README screenshots: looks like a typical PC, contains nothing from this one.
function New-MockDrive {
  $rnd = New-Object Random 7
  function MockDir($parent, $name) {
    $n = New-Object DiskTidy.Node; $n.Name = $name; $n.IsDir = $true; $n.Parent = $parent
    $n.Path = if ($parent) { Join-Path $parent.Path $name } else { $name }; if ($parent) { $parent.Kids.Add($n) }; $n }
  function MockFiles($d, $count, $exts, $prefix, $min, $max) {
    for ($i = 1; $i -le $count; $i++) {
      $f = New-Object DiskTidy.Node; $f.Name = '{0}_{1:000}.{2}' -f $prefix, $i, $exts[$rnd.Next($exts.Count)]; $f.Parent = $d; $f.Path = Join-Path $d.Path $f.Name
      $f.Size = [long]($min + [math]::Pow($rnd.NextDouble(), 2) * ($max - $min)); $f.Files = $rnd.Next(200, 900); $d.Kids.Add($f) } } # each block stands for many real files
  function MockPath($from, $rel) { $n = $from
    foreach ($s in $rel -split '\\') { $e = $null; foreach ($k in $n.Kids) { if ($k.IsDir -and $k.Name -eq $s) { $e = $k; break } }; $n = if ($e) { $e } else { MockDir $n $s } }; $n }
  $root = MockDir $null 'C:\'
  $u = MockPath $root 'Users\you'; $loc = MockPath $u 'AppData\Local'
  $tmp = MockDir $loc 'Temp'; MockFiles $tmp 70 @('tmp', 'log', 'bin') 'tmp' 200KB 60MB
  foreach ($k in 1..14) { MockFiles (MockDir $tmp "render-assets-$k") 6 @('png', 'mp4') 'frame' 5MB 70MB }
  MockFiles (MockDir $tmp 'app-sessions') 40 @('json', 'txt') 'session' 1MB 40MB
  MockFiles (MockPath $loc 'npm-cache\_cacache') 140 @('tgz') 'pkg' 100KB 9MB
  MockFiles (MockPath $loc 'Google\Chrome\User Data\Default\Cache') 90 @('bin') 'cache' 100KB 4MB
  MockFiles (MockPath $loc 'NVIDIA\DXCache') 50 @('bin') 'shader' 1MB 20MB
  MockFiles (MockDir $u 'Videos') 16 @('mp4', 'mkv', 'mov') 'recording' 300MB 4GB
  MockFiles (MockDir $u 'Pictures') 160 @('jpg', 'png', 'heic') 'IMG' 2MB 14MB
  MockFiles (MockDir $u 'Music') 120 @('mp3', 'flac') 'track' 4MB 40MB
  MockFiles (MockDir $u 'Documents') 60 @('pdf', 'docx', 'xlsx', 'zip') 'doc' 100KB 80MB
  MockFiles (MockDir $u 'Downloads') 40 @('zip', 'exe', 'iso', 'msi') 'download' 5MB 900MB
  foreach ($p in 'web-shop', 'game-mod', 'notes-app', 'api-server') {
    $pr = MockPath $u "Projects\$p"; MockFiles (MockDir $pr 'node_modules') 90 @('js', 'node', 'map') 'module' 30KB 3MB; MockFiles (MockDir $pr 'src') 40 @('ts', 'js', 'json') 'src' 5KB 400KB }
  MockFiles (MockPath $u '.gradle\caches') 60 @('jar', 'bin') 'dep' 5MB 120MB
  $w = MockDir $root 'Windows'; MockFiles (MockDir $w 'System32') 320 @('dll', 'exe', 'sys') 'sys' 100KB 30MB
  foreach ($k in 1..30) { MockFiles (MockDir (MockDir $w 'WinSxS') "amd64_component_$k") 10 @('dll', 'cat') 'part' 50KB 8MB }
  MockFiles (MockDir $w 'Installer') 30 @('msi', 'cab') 'setup' 10MB 300MB
  MockFiles (MockPath $root 'Program Files\Games\Starfall') 20 @('pak') 'data' 800MB 6GB
  MockFiles (MockPath $root 'Program Files\Adobe') 80 @('dll', 'exe') 'adobe' 1MB 60MB
  MockFiles (MockPath $root 'Program Files\NVIDIA Corporation') 50 @('dll', 'exe') 'nv' 1MB 50MB
  foreach ($f in @(@('pagefile.sys', 16GB), @('hiberfil.sys', 12.7GB))) { $n = New-Object DiskTidy.Node; $n.Name = $f[0]; $n.Size = [long]$f[1]; $n.Files = 1; $n.Parent = $root; $n.Path = "C:\$($f[0])"; $root.Kids.Add($n) }
  function Total($n) {
    if (-not $n.IsDir) { return }
    foreach ($k in $n.Kids) { Total $k }
    $n.Size = 0; $n.Files = 0; foreach ($k in $n.Kids) { $n.Size += $k.Size; $n.Files += $k.Files }
    $sorted = @($n.Kids | Sort-Object Size -Descending); $n.Kids.Clear(); foreach ($k in $sorted) { $n.Kids.Add($k) } }
  Total $root; $root
}
$cleanPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($i in $items) { foreach ($p in $i.Paths) { [void]$cleanPaths.Add($p) } }

# ---------- themes ----------
$themes = [ordered]@{
  Light    = @{ Bg = '#f5f6f8'; Panel = '#ffffff'; Fg = '#1d2228'; Muted = '#5b6570'; Line = '#d5dae0'; Btn = '#e9ecf0'; BtnHover = '#dde2e8'; Accent = '#2f6fdf'; Note = '#9a5200'; Status = '#0b62c4'; MapBg = '#ffffff'; Edge = '#8a95a1'
               Dir = '#eef0f3', '#e3e7ec', '#d8dde4', '#cdd4dc', '#c3cad3' }
  Dark     = @{ Bg = '#1e2127'; Panel = '#262a31'; Fg = '#e3e6ea'; Muted = '#9aa3ad'; Line = '#3a404a'; Btn = '#323842'; BtnHover = '#3d4450'; Accent = '#4f8cf7'; Note = '#f0b061'; Status = '#6fb1ff'; MapBg = '#181b20'; Edge = '#14161a'
               Dir = '#2b3038', '#333943', '#3b424d', '#434b57', '#4b5461' }
  Midnight = @{ Bg = '#0f1626'; Panel = '#16203a'; Fg = '#dfe7f5'; Muted = '#8fa0bf'; Line = '#2a3a5c'; Btn = '#22314f'; BtnHover = '#2c3e63'; Accent = '#6d93ff'; Note = '#ffc27a'; Status = '#8ab4ff'; MapBg = '#0c1220'; Edge = '#0a0f1a'
               Dir = '#1b2742', '#22304f', '#29395c', '#304269', '#374b76' }
  Sand     = @{ Bg = '#f4efe6'; Panel = '#fbf8f2'; Fg = '#2b2620'; Muted = '#6f6458'; Line = '#ddd3c4'; Btn = '#ebe3d5'; BtnHover = '#e0d6c5'; Accent = '#b5651d'; Note = '#9a4d00'; Status = '#8a5a00'; MapBg = '#fbf8f2'; Edge = '#a8998a'
               Dir = '#efe8dc', '#e6ddce', '#ddd2c0', '#d4c7b2', '#cbbca4' }
}
if (-not $themes.Contains($cfg.Theme)) { $cfg.Theme = 'Light' }

# ---------- UI ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DiskTidy" Width="1320" Height="960" FontFamily="Segoe UI" FontSize="13"
        Background="{DynamicResource Bg}" Foreground="{DynamicResource Fg}">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="Background" Value="{DynamicResource Btn}"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}" BorderBrush="{DynamicResource Line}" BorderThickness="1">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.82"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.65"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="B" Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ToggleButton">
      <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="Background" Value="{DynamicResource Btn}"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="B" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}" BorderBrush="{DynamicResource Line}" BorderThickness="1">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Opacity" Value="0.82"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="IsChecked" Value="True">
          <Setter Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="White"/><Setter Property="FontWeight" Value="SemiBold"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Crumb" TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Accent}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="B" Background="Transparent" CornerRadius="4" Padding="5,2"><ContentPresenter/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="B" Property="Background" Value="{DynamicResource Btn}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource Panel}"/><Setter Property="Foreground" Value="{DynamicResource Fg}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Line}"/><Setter Property="CaretBrush" Value="{DynamicResource Fg}"/><Setter Property="Padding" Value="4,3"/>
    </Style>
    <Style TargetType="ListBox">
      <Setter Property="Background" Value="{DynamicResource Panel}"/><Setter Property="Foreground" Value="{DynamicResource Fg}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
    </Style>
    <Style TargetType="ListView">
      <Setter Property="Background" Value="{DynamicResource Panel}"/><Setter Property="Foreground" Value="{DynamicResource Fg}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
    </Style>
    <Style TargetType="TreeView">
      <Setter Property="Background" Value="{DynamicResource Panel}"/><Setter Property="Foreground" Value="{DynamicResource Fg}"/><Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="GridViewColumnHeader">
          <Border Background="{DynamicResource Btn}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,1,1" Padding="6,4"><ContentPresenter HorizontalAlignment="Left"/></Border>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{DynamicResource Panel}"/><Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TabItem">
          <Border x:Name="B" Padding="16,7" Margin="0,0,4,0" CornerRadius="6,6,0,0" Background="{DynamicResource Btn}" Cursor="Hand">
            <ContentPresenter ContentSource="Header"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsSelected" Value="True">
              <Setter TargetName="B" Property="Background" Value="{DynamicResource Panel}"/>
              <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
            </Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
              <Border CornerRadius="4" Margin="2" Background="{DynamicResource Muted}" Opacity="0.55"/>
            </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track">
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb">
                  <Border CornerRadius="4" Margin="2" Background="{DynamicResource Muted}" Opacity="0.55"/>
                </ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid" Margin="12">
    <Grid.LayoutTransform><ScaleTransform x:Name="Zoom" ScaleX="1" ScaleY="1"/></Grid.LayoutTransform>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition x:Name="MapRow" Height="1*" MinHeight="140"/>
      <RowDefinition Height="12"/><RowDefinition x:Name="PanelRow" Height="1.25*" MinHeight="160"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,8">
      <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
        <ToggleButton x:Name="AutoScan" Content="Scan on start" Margin="0,0,6,0"
          ToolTip="Map the drive automatically every time DiskTidy opens. Off by default: a full scan is heavy."/>
        <Button x:Name="ThemeBtn" ToolTip="Switch colour theme. Ctrl + mouse wheel zooms the whole window, Ctrl+0 resets."/>
        <Button x:Name="ShortcutBtn" Content="Desktop shortcut" Margin="6,0,0,0"/>
      </StackPanel>
      <TextBox x:Name="Root" Width="300" VerticalContentAlignment="Center" ToolTip="Folder or drive to map. Press Enter to scan."/>
      <StackPanel x:Name="Drives" Orientation="Horizontal" Margin="6,0,0,0"/>
      <Button x:Name="ScanBtn" Content="Scan" Style="{StaticResource Primary}" Margin="6,0"/>
      <Button x:Name="UpBtn" Content="Up" ToolTip="Zoom out one level"/>
      <Button x:Name="TopBtn" Content="Top" Margin="6,0,0,0" ToolTip="Back to the scanned folder"/>
      <TextBlock x:Name="ScanInfo" VerticalAlignment="Center" Margin="12,0" Foreground="{DynamicResource Muted}" TextTrimming="CharacterEllipsis"/>
    </DockPanel>

    <DockPanel Grid.Row="1" Margin="0,0,0,6">
      <TextBlock x:Name="PathText" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="{DynamicResource Muted}" Margin="12,0,0,0"/>
      <WrapPanel x:Name="Crumbs" VerticalAlignment="Center" ToolTip="Click any folder to jump back to it. Backspace or the mouse back button goes up one level."/>
    </DockPanel>

    <DockPanel Grid.Row="2">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*" MinWidth="200"/><ColumnDefinition Width="10"/><ColumnDefinition x:Name="ListCol" Width="320" MinWidth="120"/></Grid.ColumnDefinitions>
        <Border BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="4">
          <Canvas x:Name="Map" ClipToBounds="True" Background="{DynamicResource MapBg}"/>
        </Border>
        <GridSplitter Grid.Column="1" Width="10" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Background="Transparent" Cursor="SizeWE" ToolTip="Drag to resize">
          <GridSplitter.Template><ControlTemplate TargetType="GridSplitter">
            <Border Background="Transparent"><Border Width="4" Height="44" CornerRadius="2" Background="{DynamicResource Muted}" Opacity="0.5"/></Border>
          </ControlTemplate></GridSplitter.Template>
        </GridSplitter>
        <ListBox Grid.Column="2" x:Name="Kids" FontFamily="Consolas" FontSize="12"/>
      </Grid>
    </DockPanel>

    <GridSplitter Grid.Row="3" Height="12" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" ResizeDirection="Rows" Background="Transparent" Cursor="SizeNS" ToolTip="Drag to resize the map and the panel below">
      <GridSplitter.Template><ControlTemplate TargetType="GridSplitter">
        <Border Background="Transparent"><Border Width="70" Height="4" CornerRadius="2" Background="{DynamicResource Muted}" Opacity="0.5"/></Border>
      </ControlTemplate></GridSplitter.Template>
    </GridSplitter>

    <DockPanel Grid.Row="4">
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,8">
      <TextBlock x:Name="HoverText" TextTrimming="CharacterEllipsis" Foreground="{DynamicResource Fg}"/>
      <WrapPanel x:Name="Legend" Margin="0,4,0,0"/>
    </StackPanel>
    <TabControl x:Name="Tabs" Padding="8">
      <TabItem Header="Disk cleanup">
        <DockPanel>
          <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
            <Button x:Name="CleanBtn" Content="Clean selected" Style="{StaticResource Primary}"/>
            <Button x:Name="AdminBtn" Content="Restart as admin" Margin="8,0,0,0"/>
            <Button x:Name="WinCleanBtn" Content="Windows Disk Cleanup..." Margin="8,0,0,0" ToolTip="Windows' own tool. Click 'Clean up system files' in it for old update leftovers."/>
            <TextBlock x:Name="Selected" VerticalAlignment="Center" Margin="14,0" FontWeight="SemiBold"/>
          </DockPanel>
          <TextBlock DockPanel.Dock="Top" Foreground="{DynamicResource Muted}" Margin="2,0,0,6" TextWrapping="Wrap"
            Text="Never touched: Downloads, Recycle Bin, Documents, Desktop, your projects, Docker, app settings. Right-click any line to open it in Explorer or find it in the disk map."/>
          <ScrollViewer x:Name="CleanScroll" VerticalScrollBarVisibility="Auto">
            <ItemsControl x:Name="Clean">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Border BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Padding="4,8" Background="Transparent">
                    <Grid>
                      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="26"/><ColumnDefinition Width="300"/><ColumnDefinition Width="95"/><ColumnDefinition Width="78"/><ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <CheckBox IsChecked="{Binding Checked, Mode=TwoWay}" IsEnabled="{Binding Enabled}" VerticalAlignment="Top" Margin="0,2,0,0"/>
                      <StackPanel Grid.Column="1" Margin="0,0,10,0">
                        <TextBlock Text="{Binding Name}" FontWeight="SemiBold"/>
                        <TextBlock Text="{Binding Where}" FontSize="11" Foreground="{DynamicResource Muted}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Where}"/>
                      </StackPanel>
                      <TextBlock Grid.Column="2" Text="{Binding SizeText}" HorizontalAlignment="Right" Margin="0,0,12,0" FontWeight="SemiBold"/>
                      <Border Grid.Column="3" x:Name="Badge" CornerRadius="3" Padding="6,1" HorizontalAlignment="Left" VerticalAlignment="Top" Background="#d8f0dd">
                        <TextBlock x:Name="BadgeText" Text="{Binding Safety}" FontSize="11" Foreground="#1d6b32"/>
                      </Border>
                      <StackPanel Grid.Column="4">
                        <TextBlock Text="{Binding Explanation}" TextWrapping="Wrap" Foreground="{DynamicResource Fg}"/>
                        <TextBlock Text="{Binding Status}" Foreground="{DynamicResource Status}" FontSize="12"/>
                      </StackPanel>
                      <Expander Grid.Row="1" Grid.ColumnSpan="5" x:Name="SubsBox" Header="{Binding SubsHeader}" Margin="22,6,0,0" Foreground="{DynamicResource Muted}">
                        <StackPanel Margin="0,6,0,0">
                          <Border BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="4" Height="{Binding ListHeight}" Background="{DynamicResource Panel}">
                            <TreeView ItemsSource="{Binding Subs}" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" Margin="2">
                              <TreeView.ItemContainerStyle>
                                <Style TargetType="TreeViewItem">
                                  <Setter Property="IsExpanded" Value="{Binding IsExpanded, Mode=TwoWay}"/>
                                  <Setter Property="Foreground" Value="{DynamicResource Fg}"/>
                                </Style>
                              </TreeView.ItemContainerStyle>
                              <TreeView.ItemTemplate>
                                <HierarchicalDataTemplate ItemsSource="{Binding Kids}">
                                  <StackPanel Orientation="Horizontal" Margin="0,1" Background="Transparent">
                                    <CheckBox x:Name="Chk" IsChecked="{Binding Checked, Mode=TwoWay}" IsThreeState="False" VerticalAlignment="Center"/>
                                    <TextBlock Text="{Binding SizeText}" Width="80" TextAlignment="Right" Margin="4,0,12,0" FontFamily="Consolas" Foreground="{DynamicResource Muted}"/>
                                    <TextBlock Text="{Binding Name}"/>
                                    <TextBlock Text="{Binding Note}" Foreground="{DynamicResource Note}" Margin="14,0,0,0"/>
                                  </StackPanel>
                                  <HierarchicalDataTemplate.Triggers>
                                    <DataTrigger Binding="{Binding IsPlaceholder}" Value="True"><Setter TargetName="Chk" Property="Visibility" Value="Hidden"/></DataTrigger>
                                  </HierarchicalDataTemplate.Triggers>
                                </HierarchicalDataTemplate>
                              </TreeView.ItemTemplate>
                            </TreeView>
                          </Border>
                          <Thumb Tag="grip" Height="12" Cursor="SizeNS" ToolTip="Drag to make the list taller or shorter">
                            <Thumb.Template><ControlTemplate TargetType="Thumb">
                              <Border Background="Transparent"><Border Width="70" Height="4" CornerRadius="2" Background="{DynamicResource Muted}" Opacity="0.6"/></Border>
                            </ControlTemplate></Thumb.Template>
                          </Thumb>
                        </StackPanel>
                      </Expander>
                    </Grid>
                  </Border>
                  <DataTemplate.Triggers>
                    <DataTrigger Binding="{Binding Safety}" Value="Caution">
                      <Setter TargetName="Badge" Property="Background" Value="#fde7c8"/>
                      <Setter TargetName="BadgeText" Property="Foreground" Value="#8a4b00"/>
                    </DataTrigger>
                    <DataTrigger Binding="{Binding HasSubs}" Value="False">
                      <Setter TargetName="SubsBox" Property="Visibility" Value="Collapsed"/>
                    </DataTrigger>
                  </DataTemplate.Triggers>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem x:Name="DrivesTab" Header="Drives">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="2,0,2,8"
            Text="Read-only: this tab never writes to a disk. It shows each drive's health as the drive itself reports it and warns early when one starts failing. To move Windows to a new SSD, use a cloning tool (Samsung Data Migration for Samsung drives, or Rescuezilla). To make room for a new volume without losing data, use Disk Management: right-click a volume, Shrink Volume, then New Simple Volume."/>
          <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
            <Button x:Name="DrivesRefresh" Content="Refresh" Style="{StaticResource Primary}"/>
            <Button x:Name="DiskMgmtBtn" Content="Disk Management..." Margin="8,0,0,0" ToolTip="Windows' own tool: shrink a volume, create a new one, change drive letters."/>
            <StackPanel x:Name="ToolBtns" Orientation="Horizontal"/>
            <TextBlock x:Name="DrivesInfo" VerticalAlignment="Center" Margin="14,0" Foreground="{DynamicResource Muted}" TextWrapping="Wrap"/>
          </DockPanel>
          <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="DriveList"/></ScrollViewer>
        </DockPanel>
      </TabItem>

      <TabItem x:Name="RamTab" Header="RAM cleanup">
        <DockPanel>
          <TextBlock DockPanel.Dock="Top" TextWrapping="Wrap" Margin="2,0,2,8"
            Text="Trimming never closes an app or loses data, so open Claude sessions and projects keep running. Windows moves the app's idle memory out of RAM and reloads it the moment the app needs it, so a trimmed app feels sluggish for a few seconds when you switch back. It is mostly cosmetic: Windows already does this by itself when RAM runs low. Nothing is ticked by default; pick only apps you are not using right now."/>
          <DockPanel DockPanel.Dock="Bottom" Margin="0,8,0,0">
            <Button x:Name="TrimBtn" Content="Trim selected apps" Style="{StaticResource Primary}"/>
            <Button x:Name="StandbyBtn" Content="Clear standby cache (admin)" Margin="8,0,0,0"
              ToolTip="Spare RAM Windows fills with recently read files ('Cached' in Task Manager). Clearing it loses nothing; the next file opens are just slower."/>
            <Button x:Name="RamRefresh" Content="Refresh" Margin="8,0,0,0"/>
            <TextBlock x:Name="RamInfo" VerticalAlignment="Center" Margin="14,0" FontWeight="SemiBold"/>
          </DockPanel>
          <ListView x:Name="Procs">
            <ListView.View>
              <GridView>
                <GridViewColumn Width="34"><GridViewColumn.CellTemplate><DataTemplate><CheckBox IsChecked="{Binding Checked, Mode=TwoWay}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
                <GridViewColumn Header="App" Width="190" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="Processes" Width="75" DisplayMemberBinding="{Binding Count}"/>
                <GridViewColumn Header="In RAM" Width="95" DisplayMemberBinding="{Binding MemText}"/>
                <GridViewColumn Header="What it is" Width="600" DisplayMemberBinding="{Binding Note}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </DockPanel>
      </TabItem>
    </TabControl>
    </DockPanel>
  </Grid>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'RootGrid','Zoom','Crumbs','AutoScan','MapRow','PanelRow','ListCol','CleanScroll','Root','Drives','ScanBtn','UpBtn','TopBtn','ScanInfo','PathText','Map','Kids','HoverText','Legend','Clean','CleanBtn','AdminBtn',
  'WinCleanBtn','Selected','Tabs','RamTab','DrivesTab','DrivesRefresh','DiskMgmtBtn','ToolBtns','DrivesInfo','DriveList','TrimBtn','StandbyBtn','RamRefresh','RamInfo','Procs','ThemeBtn','ShortcutBtn') { Set-Variable $n $win.FindName($n) }

$bc = New-Object Windows.Media.BrushConverter
function B($c) { $bc.ConvertFromString($c) }
function Fmt($b) { [DiskTidy.Fmt]::Size($b) }

# ---------- disk map ----------
$fileCats = [ordered]@{
  video = '#b48ead', 'mp4 mkv mov avi webm m4v wmv'
  image = '#8fbf7f', 'png jpg jpeg gif webp bmp psd tif tiff heic'
  audio = '#e5a36b', 'mp3 wav flac ogg m4a aac'
  archive = '#d77a7a', 'zip 7z rar tar gz iso cab msi'
  program = '#7fa7e0', 'exe dll sys pdb lib obj node'
  data = '#6fc2b5', 'db sqlite vhdx vhd vmdk pak bin dat log pth safetensors gguf'
  other = '#b9c0c8', ''
}
$extBrush = @{}; $catBrush = @{}
foreach ($k in $fileCats.Keys) {
  $catBrush[$k] = B $fileCats[$k][0]
  foreach ($e in ($fileCats[$k][1] -split ' ')) { if ($e) { $extBrush[$e] = $catBrush[$k] } }
  [void]$Legend.Children.Add((New-Object Windows.Controls.Border -Property @{ Width = 12; Height = 12; Background = $catBrush[$k]; Margin = '0,0,4,0'; CornerRadius = 2 }))
  $lt = New-Object Windows.Controls.TextBlock -Property @{ Text = $k; Margin = '0,0,14,0' }
  $lt.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Muted'); [void]$Legend.Children.Add($lt)
}
$legendTip = New-Object Windows.Controls.TextBlock -Property @{ Text = 'Orange outline = can be cleaned below'; Margin = '6,0,0,0' }
[void]$Legend.Children.Add($legendTip)
$groupBrush = B '#c9ced4'; $hotBrush = B '#ff8c1a'; $darkText = B '#15181c'
$script:dirBrushes = @(); $script:edgeBrush = $null; $script:fgBrush = $null
function FileBrush($n) {
  if ($n.IsGroup) { return $groupBrush }
  $b = $extBrush[[IO.Path]::GetExtension($n.Name).TrimStart('.').ToLower()]
  if ($b) { $b } else { $catBrush.other }
}
function Describe($n) {
  if (-not $n) { return 'Hover a block to see what it is. Click selects it, double-click zooms in, right-click for options.' }
  $what = if ($n.IsGroup) { "$($n.Name) in $($n.Path)" } else { $n.Path }
  "$what    $(Fmt $n.Size)$(if ($n.IsDir) { '    {0:N0} files' -f $n.Files })$(if ($cleanPaths.Contains($n.Path)) { '    (cleanable below)' })"
}

function Add-Rect($x, $y, $w, $h, $fill, $n, $label, $isDir) {
  $hot = $cleanPaths.Contains($n.Path) -and -not $n.IsGroup
  $r = New-Object Windows.Controls.Border -Property @{ Width = $w; Height = $h; Background = $fill; Tag = $n
    BorderBrush = $(if ($hot) { $hotBrush } else { $script:edgeBrush }); BorderThickness = $(if ($hot) { 2 } else { 0.5 }) }
  if ($label) { $r.Child = New-Object Windows.Controls.TextBlock -Property @{ Text = $label; FontSize = 11; Margin = '3,1,2,0'; TextTrimming = 'CharacterEllipsis'
    Foreground = $(if ($isDir) { $script:fgBrush } else { $darkText }) } }
  [Windows.Controls.Canvas]::SetLeft($r, $x); [Windows.Controls.Canvas]::SetTop($r, $y)
  [void]$Map.Children.Add($r)
}

function Draw-Level($node, [double]$x, [double]$y, [double]$w, [double]$h, [int]$depth) {
  $kids = @($node.Kids | Where-Object { $_.Size -gt 0 })
  if (-not $kids.Count) { return }
  $r = [DiskTidy.Treemap]::Layout([double[]]@($kids | ForEach-Object { [double]$_.Size }), $x, $y, $w, $h)
  for ($i = 0; $i -lt $kids.Count; $i++) {
    $k = $kids[$i]; $rx = $r[$i*4]; $ry = $r[$i*4+1]; $rw = $r[$i*4+2]; $rh = $r[$i*4+3]
    if ($rw -lt 3 -or $rh -lt 3) { continue }
    $label = if ($rw -gt 50 -and $rh -gt 15) { "$($k.Name)  $(Fmt $k.Size)" }
    if ($k.IsDir) {
      Add-Rect $rx $ry $rw $rh $script:dirBrushes[[math]::Min($depth, 4)] $k $label $true
      if ($depth -lt 4 -and $rw -gt 20 -and $rh -gt 28) { Draw-Level $k ($rx + 2) ($ry + 16) ($rw - 4) ($rh - 18) ($depth + 1) }
    } else { Add-Rect $rx $ry $rw $rh (FileBrush $k) $k $label $false }
  }
}

# Hover and selection outlines sit on top of the map and never catch the mouse.
$hov = New-Object Windows.Shapes.Rectangle -Property @{ StrokeThickness = 2; IsHitTestVisible = $false; Visibility = 'Collapsed'; Fill = (B '#22FFFFFF') }
$selRect = New-Object Windows.Shapes.Rectangle -Property @{ StrokeThickness = 3; IsHitTestVisible = $false; Visibility = 'Collapsed'; StrokeDashArray = (New-Object Windows.Media.DoubleCollection (,[double[]](3, 1.5))) }
[Windows.Controls.Panel]::SetZIndex($hov, 1000); [Windows.Controls.Panel]::SetZIndex($selRect, 1001)
function Find-Block($n) { foreach ($c in $Map.Children) { if ($c.Tag -eq $n) { return $c } } }
function Outline($rect, $block) {
  if (-not $block) { $rect.Visibility = 'Collapsed'; return }
  [Windows.Controls.Canvas]::SetLeft($rect, [Windows.Controls.Canvas]::GetLeft($block)); [Windows.Controls.Canvas]::SetTop($rect, [Windows.Controls.Canvas]::GetTop($block))
  $rect.Width = $block.Width; $rect.Height = $block.Height; $rect.Visibility = 'Visible'
}

$script:top = $null; $script:cur = $null; $script:sel = $null; $script:hoverNode = $null
$script:needDraw = $false; $script:scanTask = $null; $script:cleanTask = $null; $script:trimTask = $null
function Draw {
  $Map.Children.Clear()
  if ($script:cur -and $Map.ActualWidth -gt 10 -and $Map.ActualHeight -gt 10) { Draw-Level $script:cur 0 0 $Map.ActualWidth $Map.ActualHeight 0 }
  [void]$Map.Children.Add($hov); [void]$Map.Children.Add($selRect)
  $hov.Visibility = 'Collapsed'
  Outline $selRect $(if ($script:sel) { Find-Block $script:sel })
}
function Navigate($n) {
  $script:cur = $n
  $PathText.Text = "$(Fmt $n.Size)  -  {0:N0} files" -f $n.Files
  $Crumbs.Children.Clear()
  $chain = @(); $p = $n; while ($p) { $chain = ,$p + $chain; $p = $p.Parent }
  for ($i = 0; $i -lt $chain.Count; $i++) {
    if ($i) { $sep = New-Object Windows.Controls.TextBlock -Property @{ Text = '>'; Margin = '1,0'; VerticalAlignment = 'Center' }
      $sep.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Muted'); [void]$Crumbs.Children.Add($sep) }
    $c = $chain[$i]
    $btn = New-Object Windows.Controls.Button -Property @{ Content = $(if ($i) { $c.Name } else { $c.Path }); Tag = $c; Style = $win.FindResource('Crumb') }
    if ($i -eq $chain.Count - 1) { $btn.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'Fg') }
    $btn.add_Click({ param($s, $e) $from = $script:cur; Navigate $s.Tag; Select-Node $null })
    [void]$Crumbs.Children.Add($btn)
  }
  $Kids.Items.Clear()
  foreach ($k in $n.Kids) {
    $pct = if ($n.Size) { 100.0 * $k.Size / $n.Size } else { 0 }
    [void]$Kids.Items.Add((New-Object Windows.Controls.ListBoxItem -Property @{ Tag = $k
      Content = "{0,10} {1,5:0.0}%  {2}{3}" -f (Fmt $k.Size), $pct, $k.Name, $(if ($k.IsDir) { '\' }) }))
  }
  Draw
}
function Select-Node($n) {
  $script:sel = $n
  Outline $selRect $(if ($n) { Find-Block $n })
  $HoverText.Text = Describe $n
  foreach ($li in $Kids.Items) { if ($li.Tag -eq $n) { $Kids.SelectedItem = $li; $Kids.ScrollIntoView($li) } }
}
function Hit($e) {
  $o = $e.OriginalSource
  while ($o -and -not ($o.Tag -is [DiskTidy.Node])) { $o = [Windows.Media.VisualTreeHelper]::GetParent($o) }
  $o
}
function Find-Node($path) {
  if (-not $script:top) { return $null }
  $base = $script:top.Path.TrimEnd('\')
  if (-not $path.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { return $null }
  $n = $script:top
  foreach ($seg in ($path.Substring($base.Length).Trim('\') -split '\\')) {
    if (-not $seg) { continue }
    $next = $null; foreach ($k in $n.Kids) { if ($k.IsDir -and $k.Name -eq $seg) { $next = $k; break } }
    if (-not $next) { break }; $n = $next
  }
  $n
}
function Open-Path($p) {
  if (Test-Path -LiteralPath $p -PathType Leaf) { Start-Process explorer.exe "/select,`"$p`"" }
  elseif (Test-Path -LiteralPath $p) { Start-Process explorer.exe "`"$p`"" }
}
function Show-InMap($p) {
  $n = Find-Node $p
  if (-not $n -or $n -eq $script:top -and $p.TrimEnd('\') -ne $script:top.Path.TrimEnd('\')) {
    [Windows.MessageBox]::Show("Not in the current map. Scan a drive or folder that contains:`n$p", 'DiskTidy') | Out-Null; return }
  Navigate $(if ($n.Parent) { $n.Parent } else { $n }); Select-Node $n
}
$miOpen = { param($s, $e) Open-Path $s.Tag }
$miShow = { param($s, $e) Show-InMap $s.Tag }
$miZoom = { param($s, $e) Navigate $s.Tag }
function Show-Menu($entries) {
  $cm = New-Object Windows.Controls.ContextMenu
  foreach ($en in $entries) { $mi = New-Object Windows.Controls.MenuItem -Property @{ Header = $en[0]; Tag = $en[1] }; $mi.add_Click($en[2]); [void]$cm.Items.Add($mi) }
  $cm.IsOpen = $true
}

function Start-Scan {
  $p = $Root.Text.Trim()
  if (-not (Test-Path -LiteralPath $p -PathType Container)) { [Windows.MessageBox]::Show("Folder not found: $p") | Out-Null; return }
  $p = (Get-Item -LiteralPath $p -Force).FullName
  # Light up the drive button this scan belongs to (also for folders typed by hand).
  foreach ($b in $Drives.Children) {
    if ($p.StartsWith($b.Tag, [StringComparison]::OrdinalIgnoreCase)) { $b.Style = $win.FindResource('Primary') }
    else { $b.ClearValue([Windows.FrameworkElement]::StyleProperty) } } # back to the themed default (Style = $null would drop the theme)
  $script:scanStart = Get-Date
  $script:scanTask = [DiskTidy.Scanner]::Start($p)
  $ScanBtn.Content = 'Stop'
}

$Map.add_SizeChanged({ $script:needDraw = $true })
$Map.add_MouseMove({ param($s, $e)
  $b = Hit $e; $n = if ($b) { $b.Tag }
  if ($n -ne $script:hoverNode) { $script:hoverNode = $n; Outline $hov $b; $HoverText.Text = Describe $n } })
$Map.add_MouseLeave({ $script:hoverNode = $null; $hov.Visibility = 'Collapsed'; $HoverText.Text = Describe $script:sel })
$Map.add_MouseLeftButtonDown({ param($s, $e)
  $b = Hit $e; if (-not $b) { return }; $n = $b.Tag
  if ($e.ClickCount -ge 2) { if ($n.IsDir) { Navigate $n; Select-Node $null } } else { Select-Node $n } })
$Map.add_MouseRightButtonUp({ param($s, $e)
  $b = Hit $e; if (-not $b) { return }; $n = $b.Tag; Select-Node $n
  $m = @(, @($(if ($n.IsGroup) { 'Open folder in Explorer' } else { 'Show in Explorer' }), $n.Path, $miOpen))
  if ($n.IsDir) { $m += , @('Zoom into this folder', $n, $miZoom) }
  if ($n.Parent -and $n.Parent -ne $script:cur) { $m += , @('Zoom into its parent folder', $n.Parent, $miZoom) }
  if ($script:cur.Parent) { $m += , @('Zoom out one level', $script:cur.Parent, $miZoom) }
  Show-Menu $m })
$Kids.add_SelectionChanged({ $li = $Kids.SelectedItem; if ($li -and $li.Tag -ne $script:sel) { $script:sel = $li.Tag; Outline $selRect (Find-Block $li.Tag); $HoverText.Text = Describe $li.Tag } })
$Kids.add_MouseDoubleClick({ $n = $Kids.SelectedItem.Tag; if ($n -and $n.IsDir) { Navigate $n; Select-Node $null } })
$Kids.add_MouseRightButtonUp({ $n = $Kids.SelectedItem.Tag; if ($n) { Show-Menu @(, @('Show in Explorer', $n.Path, $miOpen)) } })
$UpBtn.add_Click({ if ($script:cur -and $script:cur.Parent) { $from = $script:cur; Navigate $script:cur.Parent; Select-Node $from } })
$TopBtn.add_Click({ if ($script:top) { Navigate $script:top; Select-Node $null } })
$ScanBtn.add_Click({ if ($script:scanTask) { [DiskTidy.Scanner]::Cancel = $true } else { Start-Scan } })
$Root.add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return' -and -not $script:scanTask) { Start-Scan } })
foreach ($d in [IO.DriveInfo]::GetDrives()) {
  if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady -or ($Shot -and $d.Name -ne 'C:\')) { continue } # screenshots: no hint of your other drives
  $btn = New-Object Windows.Controls.Button -Property @{ Content = $d.Name.TrimEnd('\'); Tag = $d.Name; Margin = '0,0,4,0'; Padding = '8,5'
    ToolTip = "$($d.Name)  $(Fmt $d.AvailableFreeSpace) free of $(Fmt $d.TotalSize)" }
  $btn.add_Click({ param($s, $e) if (-not $script:scanTask) { $Root.Text = $s.Tag; Start-Scan } })
  [void]$Drives.Children.Add($btn)
}

# ---------- cleanup list ----------
$Clean.add_MouseRightButtonUp({ param($s, $e)
  $d = $e.OriginalSource.DataContext
  if ($d -is [DiskTidy.SubItem] -and -not $d.IsPlaceholder) {
    $inMap = if ($d.Kind -eq 'Folder' -or $d.Kind -eq 'File') { $d.Paths[0] } else { $d.Open }
    Show-Menu @(@('Open in Explorer', $d.Open, $miOpen), @('Show in disk map', $inMap, $miShow))
  } elseif ($d -is [DiskTidy.CleanItem]) {
    $m = @(); foreach ($p in ($d.Paths | Select-Object -First 8)) { $m += , @("Open  $p", $p, $miOpen) }
    $m += , @('Show in disk map', $d.Paths[0], $miShow)
    Show-Menu $m
  } })
$Clean.AddHandler([Windows.Controls.Primitives.Thumb]::DragDeltaEvent, [Windows.Controls.Primitives.DragDeltaEventHandler]{ param($s, $e)
  if ($e.OriginalSource.Tag -eq 'grip') { $it = $e.OriginalSource.DataContext; $it.ListHeight = [math]::Max(80, [math]::Min(1400, $it.ListHeight + $e.VerticalChange)); $e.Handled = $true } })
$AdminBtn.Visibility = if ($isAdmin) { 'Collapsed' } else { 'Visible' }
$AdminBtn.add_Click({
  Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  $win.Close() })
$WinCleanBtn.add_Click({ Start-Process cleanmgr.exe })
$CleanBtn.add_Click({
  $sel = @($items | Where-Object { $_.Checked -and $_.Enabled -and $_.SelectedSize -gt 0 })
  if (-not $sel) { [Windows.MessageBox]::Show('Nothing ticked.', 'DiskTidy') | Out-Null; return }
  $list = ($sel | ForEach-Object { $k = @($_.Subs | Where-Object { $_.Checked -ne $true }).Count
    " - $($_.Name)  ($(Fmt $_.SelectedSize))$(if ($k) { ", keeping $k unticked entries" })" }) -join "`n"
  $msg = "Delete:`n$list`n`nOpen files and anything changed recently are left alone.`nDownloads, Recycle Bin and your own files are never touched.`n`nContinue?"
  if ([Windows.MessageBox]::Show($msg, 'DiskTidy', 'YesNo', 'Question') -ne 'Yes') { return }
  $CleanBtn.IsEnabled = $false
  $script:cleanTask = [DiskTidy.Cleaner]::CleanAll($items) })

# ---------- RAM ----------
$procNotes = [ordered]@{
  'claude' = 'Claude app and Claude Code sessions. Safe: sessions keep running, they just reload memory for a few seconds.'
  'chrome|msedge|firefox|waterfox|floorp|librewolf|comet|brave|opera' = 'Browser. Safe; tabs stay open, background tabs reload memory when you click them.'
  'Code|Cursor|idea64|pycharm64|webstorm64|rider64|devenv' = 'Code editor / IDE. Safe; expect a short lag when you switch back.'
  'node|python|pythonw|bun|deno|java' = 'Dev servers and scripts. Safe; the first request after may be slower.'
  'vmmem|vmmemWSL|com.docker.backend|Docker Desktop' = 'WSL / Docker virtual machine. Trimming barely helps; stop Docker to really free it.'
  'Resolve|AfterFX|Photoshop|obs64|Cinema 4D|HandBrake|Premiere Pro|blender' = 'Heavy creative app. Safe, but it stalls for a moment when you return. Never during a render or recording.'
  'Discord|Signal|Telegram|Obsidian|Anki|Slack|Spotify' = 'Chat / notes / music app. Safe.'
  'dwm|csrss|explorer|MsMpEng|svchost|lsass|wininit|services|smss|Registry|Memory Compression|SearchHost|StartMenuExperienceHost' = 'Part of Windows. Harmless but pointless; Windows manages these itself.'
}
function ProcNote($name) { foreach ($k in $procNotes.Keys) { if ($name -match "^($k)$") { return $procNotes[$k] } }; '' }
function Refresh-Ram {
  $RamInfo.Text = ''
  $keep = @($Procs.ItemsSource | Where-Object Checked | ForEach-Object Name)
  $list = [DiskTidy.Ram]::List()
  foreach ($p in $list) { $p.Note = ProcNote $p.Name; if ($keep -contains $p.Name) { $p.Checked = $true } }
  $Procs.ItemsSource = $list
}
function Ram-Text { $t = [DiskTidy.Ram]::Total(); $a = [DiskTidy.Ram]::Avail(); "RAM in use: $(Fmt ($t - $a)) of $(Fmt $t)   ($(Fmt $a) available)" }
$Tabs.add_SelectionChanged({ param($s, $e)
  if ($e.OriginalSource -ne $Tabs) { return }
  if ($Tabs.SelectedItem -eq $RamTab) { Refresh-Ram }
  if ($Tabs.SelectedItem -eq $DrivesTab -and -not $script:drivesLoaded) { Start-Drives } })

# ---------- Drives ----------
$script:driveJob = $null; $script:drivesLoaded = $false
function Start-Drives {
  if ($script:driveJob) { return }
  if ($Shot) { # screenshots for the README use made-up drives, never the real ones
    $ToolBtns.Children.Clear()
    Show-Drives @(
      [pscustomobject]@{ Number = 0; Name = 'NVMe SSD 1TB'; Media = 'SSD'; Bus = 'NVMe'; Size = 1TB; Health = 'Healthy'; Status = 'OK'; HasRc = $true; Temp = 41; TempMax = 70; Wear = 3; Hours = 5210; ReadErr = 0; WriteErr = 0
        Parts = @([pscustomobject]@{ Letter = ''; Type = 'System'; Size = 100MB; Free = -1 }, [pscustomobject]@{ Letter = 'C:'; Type = 'Basic'; Size = 930GB; Free = 412GB; Label = 'Windows'; FS = 'NTFS'; IsBoot = $true },
                  [pscustomobject]@{ Letter = ''; Type = 'Recovery'; Size = 750MB; Free = -1 }) }
      [pscustomobject]@{ Number = 1; Name = 'SATA HDD 2TB'; Media = 'HDD'; Bus = 'SATA'; Size = 2TB; Health = 'Warning'; Status = 'Predictive Failure'; HasRc = $true; Temp = 46; TempMax = 60; Wear = $null; Hours = 31870; ReadErr = 12; WriteErr = 0
        Parts = @([pscustomobject]@{ Letter = 'D:'; Type = 'Basic'; Size = 1.8TB; Free = 610GB; Label = 'Data'; FS = 'NTFS'; IsBoot = $false }) })
    $script:drivesLoaded = $true; return
  }
  $DrivesInfo.Text = 'Reading drives...'
  $ps = [powershell]::Create(); [void]$ps.AddScript($collectDrives.ToString())
  $script:driveJob = @{ PS = $ps; Async = $ps.BeginInvoke() }
}
function TB($text, $size = 13, $weight = 'Normal', $res = 'Fg', $margin = '0') {
  $t = New-Object Windows.Controls.TextBlock -Property @{ Text = $text; FontSize = $size; FontWeight = $weight; Margin = $margin; TextWrapping = 'Wrap' }
  $t.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $res); $t
}
function Usage-Bar($used, $total) {
  $g = New-Object Windows.Controls.Grid -Property @{ Width = 160; Height = 8; Margin = '10,0'; VerticalAlignment = 'Center' }
  $bg = New-Object Windows.Controls.Border -Property @{ CornerRadius = 4 }; $bg.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Line')
  $pct = if ($total -gt 0) { [math]::Min(1.0, $used / $total) } else { 0 } # 1.0, not 1: the int overload rounds 0.56 up to 1
  $fg = New-Object Windows.Controls.Border -Property @{ CornerRadius = 4; HorizontalAlignment = 'Left'; Width = 160 * $pct }
  if ($pct -ge 0.9) { $fg.Background = B '#d9534f' } else { $fg.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Accent') }
  [void]$g.Children.Add($bg); [void]$g.Children.Add($fg); $g
}
$partNames = @{ System = 'EFI boot partition (Windows needs it to start)'; Reserved = 'Microsoft reserved (system use)'; Recovery = 'Windows recovery tools'; Unknown = 'Other / unknown partition' }
function Show-Drives($list) {
  $DriveList.Children.Clear()
  foreach ($d in $list) {
    $card = New-Object Windows.Controls.Border -Property @{ CornerRadius = 6; Padding = '14,10'; Margin = '0,0,0,10'; BorderThickness = 1 }
    $card.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'Bg'); $card.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Line')
    $sp = New-Object Windows.Controls.StackPanel; $card.Child = $sp
    $head = New-Object Windows.Controls.WrapPanel
    [void]$head.Children.Add((TB "Disk $($d.Number):  $($d.Name)" 15 'SemiBold'))
    $ok = $d.Health -eq 'Healthy'
    $badge = New-Object Windows.Controls.Border -Property @{ CornerRadius = 3; Padding = '6,1'; Margin = '10,2,0,0'; VerticalAlignment = 'Top'
      Background = (B $(if ($ok) { '#d8f0dd' } elseif ($d.Health -eq 'Warning') { '#fde7c8' } else { '#f8d0cf' }))
      Child = (New-Object Windows.Controls.TextBlock -Property @{ Text = $(if ($d.Health) { $d.Health } else { 'Unknown' }); FontSize = 11
        Foreground = (B $(if ($ok) { '#1d6b32' } elseif ($d.Health -eq 'Warning') { '#8a4b00' } else { '#8b1d1a' })) }) }
    [void]$head.Children.Add($badge); [void]$sp.Children.Add($head)
    [void]$sp.Children.Add((TB "$(Fmt $d.Size)   $($d.Media)   $($d.Bus)" 12 'Normal' 'Muted' '0,2,0,6'))
    $m = if ($d.HasRc) {
      $bits = @()
      if ($null -ne $d.Temp -and $d.Temp -gt 0) { $bits += "Temperature $($d.Temp) C$(if ($d.TempMax) { " (rated max $($d.TempMax) C)" })" }
      if ($null -ne $d.Wear) { $bits += "Life used $($d.Wear)%" }
      if ($d.Hours) { $bits += "Powered on {0:N0} h" -f $d.Hours }
      if ($null -ne $d.ReadErr -or $null -ne $d.WriteErr) { $bits += "Uncorrected errors: $([int]$d.ReadErr) read, $([int]$d.WriteErr) write" }
      if ($bits) { $bits -join '    |    ' } else { 'The drive does not report temperature, wear or error counts.' }
    } else { 'Temperature, life used and error counts need admin: use "Restart as admin" on the Disk cleanup tab.' }
    [void]$sp.Children.Add((TB $m 12 'Normal' 'Fg' '0,0,0,6'))
    foreach ($w in (Drive-Warnings $d)) { [void]$sp.Children.Add((TB "!  $w" 13 'SemiBold' 'Note' '0,0,0,4')) }
    foreach ($p in $d.Parts) {
      $row = New-Object Windows.Controls.DockPanel -Property @{ Margin = '12,3,0,0'; LastChildFill = $true }
      $name = if ($p.Letter) { "$($p.Letter)  $(if ($p.Label) { $p.Label } else { 'Local Disk' })  ($($p.FS))$(if ($p.IsBoot) { '  - Windows runs from here' })" }
              elseif ($partNames[$p.Type]) { $partNames[$p.Type] } else { "$($p.Type) partition" }
      $left = TB $name 12 $(if ($p.Letter) { 'SemiBold' } else { 'Normal' }) $(if ($p.Letter) { 'Fg' } else { 'Muted' })
      $left.Width = 360; $left.TextTrimming = 'CharacterEllipsis'; $left.TextWrapping = 'NoWrap'
      [Windows.Controls.DockPanel]::SetDock($left, 'Left'); [void]$row.Children.Add($left)
      if ($p.Free -ge 0) {
        $bar = Usage-Bar ($p.Size - $p.Free) $p.Size; [Windows.Controls.DockPanel]::SetDock($bar, 'Left'); [void]$row.Children.Add($bar)
        [void]$row.Children.Add((TB "$(Fmt $p.Free) free of $(Fmt $p.Size)" 12 'Normal' 'Muted'))
      } else { [void]$row.Children.Add((TB (Fmt $p.Size) 12 'Normal' 'Muted')) }
      [void]$sp.Children.Add($row)
    }
    [void]$DriveList.Children.Add($card)
  }
  $bad = @($list | Where-Object { @(Drive-Warnings $_).Count })
  $DrivesInfo.Text = if ($bad) { "$($bad.Count) drive(s) need attention, see the warnings above." } else { "$(@($list).Count) drives, no problems reported. Checked $(Get-Date -Format 'HH:mm')." }
}
$DrivesRefresh.add_Click({ Start-Drives })
$DiskMgmtBtn.add_Click({ Start-Process diskmgmt.msc })
# Buttons for disk tools already installed (found by their Start menu shortcuts).
$menus = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
$seen = @{}
foreach ($tool in 'Samsung Data Migration', 'Samsung Magician', 'Rescuezilla', 'Macrium Reflect', 'Hasleo Disk Clone', 'CrystalDiskInfo*', 'HDSentinel', 'Hard Disk Sentinel') {
  $lnk = Get-ChildItem $menus -Recurse -Filter "$tool*.lnk" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $lnk -or $seen[$lnk.BaseName]) { continue }; $seen[$lnk.BaseName] = 1
  $b = New-Object Windows.Controls.Button -Property @{ Content = $lnk.BaseName; Tag = $lnk.FullName; Margin = '8,0,0,0'; ToolTip = "Open $($lnk.BaseName)" }
  $b.add_Click({ param($s, $e) Start-Process $s.Tag }); [void]$ToolBtns.Children.Add($b)
}
$RamRefresh.add_Click({ Refresh-Ram })
$TrimBtn.add_Click({
  if (-not @($Procs.ItemsSource | Where-Object Checked)) { [Windows.MessageBox]::Show('Tick the apps to trim first.', 'DiskTidy') | Out-Null; return }
  $TrimBtn.IsEnabled = $false; $script:trimTask = [DiskTidy.Ram]::Trim($Procs.ItemsSource) })
$StandbyBtn.add_Click({
  if (-not $isAdmin) { [Windows.MessageBox]::Show('Clearing the standby cache needs admin. Use "Restart as admin" on the Disk cleanup tab.', 'DiskTidy') | Out-Null; return }
  $before = [DiskTidy.Ram]::Avail(); $err = [DiskTidy.Ram]::PurgeStandby()
  $msg = if ($err) { "Could not clear standby cache: $err" } else { "Standby cache cleared. Available RAM: $(Fmt $before) -> $(Fmt ([DiskTidy.Ram]::Avail()))" }
  [Windows.MessageBox]::Show($msg, 'DiskTidy') | Out-Null })

# ---------- themes, zoom, icon, shortcut ----------
function Apply-Theme($name) {
  $t = $themes[$name]
  foreach ($k in $t.Keys) { if ($k -ne 'Dir') { $win.Resources[$k] = B $t[$k] } }
  $script:dirBrushes = @($t.Dir | ForEach-Object { B $_ })
  $script:edgeBrush = B $t.Edge; $script:fgBrush = B $t.Fg
  $hov.Stroke = $script:fgBrush; $selRect.Stroke = B $t.Accent
  $ThemeBtn.Content = "Theme: $name"
  $cfg.Theme = $name; $script:needDraw = $true
}
$ThemeBtn.add_Click({ $names = @($themes.Keys); Apply-Theme $names[($names.IndexOf($cfg.Theme) + 1) % $names.Count]; Save-Cfg })
function Set-Zoom([double]$z) {
  $z = [math]::Round([math]::Max(0.6, [math]::Min(2.0, $z)), 2)
  $Zoom.ScaleX = $z; $Zoom.ScaleY = $z; $cfg.Zoom = $z; $win.Title = if ($z -eq 1) { 'DiskTidy' } else { "DiskTidy  ($([int]($z * 100))%)" }
}
$win.add_PreviewMouseWheel({ param($s, $e)
  if ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control) { Set-Zoom ($cfg.Zoom + [math]::Sign($e.Delta) * 0.1); Save-Cfg; $e.Handled = $true } })
$win.add_PreviewKeyDown({ param($s, $e)
  if ($e.Key -eq 'D0' -and ([Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control)) { Set-Zoom 1; Save-Cfg; $e.Handled = $true }
  elseif ($e.Key -eq 'Back' -and -not ($e.OriginalSource -is [Windows.Controls.TextBox]) -and $script:cur.Parent) { $from = $script:cur; Navigate $script:cur.Parent; Select-Node $from; $e.Handled = $true } })
$win.add_PreviewMouseUp({ param($s, $e)
  if ($e.ChangedButton -eq 'XButton1' -and $script:cur.Parent) { $from = $script:cur; Navigate $script:cur.Parent; Select-Node $from; $e.Handled = $true } })
# Fit the window to the screen (it was cut off on laptops with display scaling).
$wa = [Windows.SystemParameters]::WorkArea
$win.Width = [math]::Min(1320, $wa.Width * 0.94); $win.Height = [math]::Min(980, $wa.Height * 0.94)
if ($Shot) { $win.Width = 1320; $win.Height = 1000; $PanelRow.Height = New-Object Windows.GridLength 1.5, 'Star' } # same-size README pictures on any screen
$win.WindowStartupLocation = 'CenterScreen'
$ico = Join-Path $PSScriptRoot 'DiskTidy.ico'
if (Test-Path $ico) { $win.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$ico) }
$ShortcutBtn.add_Click({
  $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DiskTidy.lnk'
  $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sh.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $sh.Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
  $sh.WorkingDirectory = $PSScriptRoot; $sh.IconLocation = "$ico,0"; $sh.WindowStyle = 7; $sh.Description = 'DiskTidy: disk map and safe cleanup'; $sh.Save()
  [Windows.MessageBox]::Show("Shortcut created on your Desktop:`n$lnk", 'DiskTidy') | Out-Null })

# ---------- background work polling ----------
$timer = New-Object Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(300) }
$timer.add_Tick({
  if ($script:scanTask) {
    if ($script:scanTask.IsCompleted) {
      $t = $script:scanTask; $script:scanTask = $null; $ScanBtn.Content = 'Scan'
      try { $root = $t.Result; $script:top = $root
        $ScanInfo.Text = "{0:N0} files, {1} in {2:0}s{3}" -f $root.Files, (Fmt $root.Size), ((Get-Date) - $script:scanStart).TotalSeconds, $(if ([DiskTidy.Scanner]::Cancel) { ' (stopped early)' })
        if (-not $Shot) { try { $d = [IO.DriveInfo]::new($root.Path.Substring(0, 3)); $ScanInfo.Text +="    |    $($d.Name) free: $(Fmt $d.AvailableFreeSpace) of $(Fmt $d.TotalSize)" } catch { } }
        $script:sel = $null; Navigate $root; $HoverText.Text = Describe $null } catch { $ScanInfo.Text = "Scan failed: $($_.Exception.InnerException.Message)" }
    } else { $ScanInfo.Text = "Scanning...  {0:N0} files, {1}" -f [DiskTidy.Scanner]::Files, (Fmt ([DiskTidy.Scanner]::Bytes)) }
  }
  if ($script:cleanTask -and $script:cleanTask.IsCompleted) {
    $t = $script:cleanTask; $script:cleanTask = $null; $CleanBtn.IsEnabled = $true
    $msg = try { "Freed $(Fmt $t.Result). Press Scan to refresh the map." } catch { "Cleanup error: $($_.Exception.InnerException.Message)" }
    [Windows.MessageBox]::Show($msg, 'DiskTidy') | Out-Null
  }
  if ($script:trimTask -and $script:trimTask.IsCompleted) {
    $t = $script:trimTask; $script:trimTask = $null; $TrimBtn.IsEnabled = $true
    $f = try { $t.Result } catch { 0 }
    Refresh-Ram; $RamInfo.Text = "Trimmed: about $(Fmt ([math]::Max(0, $f))) moved out of RAM.    " + (Ram-Text)
  } elseif ($Tabs.SelectedItem -eq $RamTab -and -not $script:trimTask -and $RamInfo.Text -notlike 'Trimmed*') { $RamInfo.Text = Ram-Text }
  if ($script:driveJob -and $script:driveJob.Async.IsCompleted) {
    $j = $script:driveJob; $script:driveJob = $null
    try { Show-Drives @($j.PS.EndInvoke($j.Async)); $script:drivesLoaded = $true } catch { $DrivesInfo.Text = "Could not read drives: $($_.Exception.Message)" }
    $j.PS.Dispose()
  }
  if ($script:needDraw) { $script:needDraw = $false; Draw }
  $sum = 0; foreach ($i in $items) { $sum += if ($Shot -and -not $i.HasSubs) { if ($i.Checked -and $i.Enabled) { $i.Size } else { 0 } } else { $i.SelectedSize } }
  $Selected.Text = "Selected: $(Fmt $sum)"
  if ($Shot -and -not $script:scanTask -and $script:top -and $script:measure.IsCompleted -and ($Tab -ne 'Drives' -or $script:drivesLoaded)) {
    $script:shotTicks++
    if ($script:shotTicks -eq 2) { # open the first "Choose what to delete" list so the picture shows it
      $stack = New-Object Collections.Stack; $stack.Push($Clean)
      while ($stack.Count) { $v = $stack.Pop(); if ($v -is [Windows.Controls.Expander]) { $v.IsExpanded = $true; break }
        for ($k = [Windows.Media.VisualTreeHelper]::GetChildrenCount($v) - 1; $k -ge 0; $k--) { $stack.Push([Windows.Media.VisualTreeHelper]::GetChild($v, $k)) } }
    }
    if ($script:shotTicks -eq 4) { # let the layout settle, then save a picture of the window for the README
      $c = $win.Content; $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$c.ActualWidth + 24), ([int]$c.ActualHeight + 24), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
      $bg = New-Object Windows.Media.DrawingVisual; $dc = $bg.RenderOpen(); $dc.DrawRectangle($win.Background, $null, (New-Object Windows.Rect 0, 0, $bmp.PixelWidth, $bmp.PixelHeight)); $dc.Close()
      $bmp.Render($bg); $bmp.Render($c)
      $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
      $fs = [IO.File]::Create($Shot); $enc.Save($fs); $fs.Close()
      $Error | Select-Object -First 5 | ForEach-Object { [Console]::Error.WriteLine("$_ @ $($_.InvocationInfo.ScriptLineNumber)") } # surface UI errors when run headless
      $win.Close()
    }
  }
})

Apply-Theme $cfg.Theme
Set-Zoom $cfg.Zoom
$HoverText.Text = Describe $null
$Clean.ItemsSource = $items
$Root.Text = $ScanPath
$script:shotTicks = 0
$AutoScan.IsChecked = $cfg.AutoScan
function AutoScan-Label { $AutoScan.Content = if ($AutoScan.IsChecked) { 'Scan on start: ON' } else { 'Scan on start: OFF' } }
AutoScan-Label
$AutoScan.add_Click({ $cfg.AutoScan = [bool]$AutoScan.IsChecked; AutoScan-Label; Save-Cfg })
if ($Tab) { foreach ($ti in $Tabs.Items) { if ("$($ti.Header)" -like "$Tab*") { $Tabs.SelectedItem = $ti } } }
# Remember splitter sizes and the cleanup list's scroll position between launches (not in screenshot mode, so README shots stay the same).
if (-not $Shot) {
  if ($cfg.MapH -gt 0 -and $cfg.PanelH -gt 0) { $MapRow.Height = New-Object Windows.GridLength $cfg.MapH, 'Star'; $PanelRow.Height = New-Object Windows.GridLength $cfg.PanelH, 'Star' }
  if ($cfg.ListW -ge 120) { $ListCol.Width = New-Object Windows.GridLength $cfg.ListW }
  $win.add_Closing({
    $cfg.MapH = [math]::Round($MapRow.ActualHeight); $cfg.PanelH = [math]::Round($PanelRow.ActualHeight)
    $cfg.ListW = [math]::Round($ListCol.ActualWidth); $cfg.Scroll = [math]::Round($CleanScroll.VerticalOffset); Save-Cfg })
}
$win.add_ContentRendered({
  if (-not $Shot -and $cfg.Scroll -gt 0) { $CleanScroll.ScrollToVerticalOffset($cfg.Scroll) }
  $script:measure = if ($Shot) { [Threading.Tasks.Task]::FromResult(0) } else { [DiskTidy.Cleaner]::MeasureAll($items) }
  if ($Shot) {
    $m = New-MockDrive; $script:top = $m; $Root.Text = 'C:\'
    foreach ($b in $Drives.Children) { $b.Style = $win.FindResource('Primary') }
    $ScanInfo.Text = "{0:N0} files, {1} in 6s" -f $m.Files, (Fmt $m.Size); Navigate $m; $script:needDraw = $true
  } elseif ($cfg.AutoScan) { Start-Scan } else { $PathText.Text = 'Nothing scanned yet: pick a drive or type a folder, then press Scan.' } }) # no auto-scan: a full drive scan is heavy
$timer.Start()
[void]$win.ShowDialog()
[DiskTidy.Scanner]::Cancel = $true
