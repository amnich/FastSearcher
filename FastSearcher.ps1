#Requires -Version 5.1
<#
.SYNOPSIS
    FastSearcher — Advanced, ultra-fast search tool for PowerShell (.ps1) and Markdown (.md) scripts.

.DESCRIPTION
    A WPF windowed application in Dark Mode for lightning-fast, multi-threaded searching of
    scripts and documentation in a selected folder and its subfolders (default D:\Skrypty).

    Main features:
      - Parallel C# search (Parallel.ForEach) scanning thousands of files in a few hundred milliseconds.
      - Smart query parsing:
          * Words separated by spaces: BC AD compare -> finds files containing all 3 phrases in any order (AND).
          * Quoted phrases: BC "AD compare" -> finds 2 phrases: [BC] and [AD compare].
      - Date filter: dynamic DatePicker with description, quick presets (Today, 24h, 5d, 30d, etc.),
        and instant clear (all files by default).
      - Hierarchical tree view (TreeView) on the left showing only folders containing matches,
        with icons, sizes, and timestamps.
      - Expand / Collapse All button for the whole tree.
      - File content preview after clicking a file in the tree.
      - Match Navigator (Previous / Next) highlighting and scrolling
        directly to the found phrases in the file's code.
      - Configuration persistence in config.json (default path, filters, preferences).
      - Context actions: Open file, Open in VS Code, Open folder in Explorer, Copy path.
      - Multi-language UI (EN/DE/PL) via external language.json file.

.NOTES
    Author: Adam Mnich
    Encoding: UTF-8 with BOM
#>

# ── 1. Force STA mode for WPF ────────────────────────────────────────────────
$scriptFile = if ($PSCommandPath) { $PSCommandPath } else { 'D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher\FastSearcher.ps1' }
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $currentProcess = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($currentProcess -match 'powershell\.exe|pwsh\.exe') {
        Start-Process -FilePath $currentProcess -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$scriptFile`""
        exit
    }
}

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force -ErrorAction SilentlyContinue

# ── 2. Load GUI libraries and Windows DWM Dark Mode ──────────────────────────
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

# DWM Dark Mode for the window title bar in Windows 10/11
if (-not ([System.Management.Automation.PSTypeName]'DwmWindowDarkHelper').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DwmWindowDarkHelper {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);

    /// <summary>Sets the title bar dark/light mode. darkMode=1 for dark, darkMode=0 for light.</summary>
    public static void SetTitleBarMode(IntPtr hwnd, int darkMode) {
        int val = darkMode;
        int res = DwmSetWindowAttribute(hwnd, 20, ref val, 4);
        if (res != 0) {
            DwmSetWindowAttribute(hwnd, 19, ref val, 4);
        }
    }

    /// <summary>Convenience wrapper — enables the dark title bar (legacy name kept for compatibility).</summary>
    public static void EnableDarkTitle(IntPtr hwnd) { SetTitleBarMode(hwnd, 1); }
}
"@ -ErrorAction SilentlyContinue
}

# ── 3. Compile the C# search engine (FastSearchEngineV2, FileNodeV2, MatchLocationV2)
if (-not ([System.Management.Automation.PSTypeName]'FastSearchEngineV2').Type) {
    $csharpEngine = @"
using System;
using System.IO;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Text.RegularExpressions;

public class SearchResultItemV2 {
    public string FullPath { get; set; }
    public string FileName { get; set; }
    public string RelativePath { get; set; }
    public string Extension { get; set; }
    public long Length { get; set; }
    public DateTime LastWriteTime { get; set; }
}

public class MatchLocationV2 {
    public int Index { get; set; }
    public int Length { get; set; }
    public int LineNumber { get; set; }
    public string Token { get; set; }
}

public class FileNodeV2 {
    public string Name { get; set; }
    public string FullPath { get; set; }
    public bool IsFolder { get; set; }
    public string Icon { get; set; }
    public string Subtitle { get; set; }
    public bool IsExpanded { get; set; }
    public List<FileNodeV2> Children { get; set; }

    public FileNodeV2() {
        Children = new List<FileNodeV2>();
        IsExpanded = true;
    }

    public static FileNodeV2 BuildTree(string rootPath, IEnumerable<SearchResultItemV2> files, bool autoExpand) {
        var root = new FileNodeV2();
        root.Name = Path.GetFileName(rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        root.FullPath = rootPath;
        root.IsFolder = true;
        root.Icon = "📁";
        root.IsExpanded = autoExpand;
        if (string.IsNullOrEmpty(root.Name)) {
            root.Name = rootPath;
        }

        var dirLookup = new Dictionary<string, FileNodeV2>(StringComparer.OrdinalIgnoreCase);
        dirLookup[rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)] = root;

        foreach (var file in files) {
            string dirPath = Path.GetDirectoryName(file.FullPath);
            FileNodeV2 parentNode = GetOrCreateDirNode(rootPath, dirPath, root, dirLookup, autoExpand);

            var fileNode = new FileNodeV2();
            fileNode.Name = file.FileName;
            fileNode.FullPath = file.FullPath;
            fileNode.IsFolder = false;
                        string ext = (file.Extension ?? "").ToLowerInvariant();
            if (ext == ".ps1" || ext == ".psm1" || ext == ".psd1") fileNode.Icon = "⚡";
            else if (ext == ".md" || ext == ".markdown") fileNode.Icon = "📝";
            else if (ext == ".sql") fileNode.Icon = "🗄️";
            else if (ext == ".json" || ext == ".yaml" || ext == ".yml" || ext == ".toml") fileNode.Icon = "📦";
            else if (ext == ".xml" || ext == ".html" || ext == ".htm" || ext == ".xaml") fileNode.Icon = "📰";
            else if (ext == ".txt" || ext == ".log" || ext == ".ini" || ext == ".cfg" || ext == ".conf") fileNode.Icon = "📋";
            else if (ext == ".csv" || ext == ".tsv") fileNode.Icon = "📊";
            else if (ext == ".cs" || ext == ".py" || ext == ".js" || ext == ".ts" || ext == ".cpp" || ext == ".c" || ext == ".h") fileNode.Icon = "💻";
            else if (ext == ".bat" || ext == ".cmd" || ext == ".sh") fileNode.Icon = "⚙️";
            else fileNode.Icon = "📄";
            fileNode.Subtitle = string.Format("{0:N0} KB | {1:yyyy-MM-dd HH:mm}", file.Length / 1024.0, file.LastWriteTime);
            fileNode.IsExpanded = false;
            parentNode.Children.Add(fileNode);
        }

        SortRecursively(root);
        return root;
    }

    private static FileNodeV2 GetOrCreateDirNode(string rootPath, string dirPath, FileNodeV2 root, Dictionary<string, FileNodeV2> lookup, bool autoExpand) {
        if (string.IsNullOrEmpty(dirPath)) return root;
        string cleanDirPath = dirPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        FileNodeV2 existing;
        if (lookup.TryGetValue(cleanDirPath, out existing)) {
            return existing;
        }

        if (cleanDirPath.Equals(rootPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar), StringComparison.OrdinalIgnoreCase)) {
            return root;
        }

        string parentDir = Path.GetDirectoryName(cleanDirPath);
        FileNodeV2 parentNode = GetOrCreateDirNode(rootPath, parentDir, root, lookup, autoExpand);

        var node = new FileNodeV2();
        node.Name = Path.GetFileName(cleanDirPath);
        node.FullPath = cleanDirPath;
        node.IsFolder = true;
        node.Icon = "📁";
        node.IsExpanded = autoExpand;
        parentNode.Children.Add(node);
        lookup[cleanDirPath] = node;
        return node;
    }

    private static void SortRecursively(FileNodeV2 node) {
        node.Children.Sort((a, b) => {
            if (a.IsFolder && !b.IsFolder) return -1;
            if (!a.IsFolder && b.IsFolder) return 1;
            return string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase);
        });

        foreach (var c in node.Children) {
            if (c.IsFolder) SortRecursively(c);
        }
    }
}

public class FastSearchEngineV2 {
    public static string[] ParseTokens(string query) {
        if (string.IsNullOrWhiteSpace(query)) return new string[0];
        var tokens = new List<string>();
        var regex = new Regex(@"""(?<q>[^""]*)""|'(?<q>[^']*)'|(?<u>[^\s""',;]+)");
        var matches = regex.Matches(query);
        foreach (Match m in matches) {
            if (m.Groups["q"].Success) {
                var val = m.Groups["q"].Value;
                if (!string.IsNullOrEmpty(val)) {
                    tokens.Add(val);
                }
            } else if (m.Groups["u"].Success) {
                var val = m.Groups["u"].Value.Trim();
                if (!string.IsNullOrEmpty(val)) {
                    tokens.Add(val);
                }
            }
        }
        return tokens.ToArray();
    }

    public static bool IsWordChar(char c) {
        return char.IsLetterOrDigit(c) || c == '_';
    }

    public static bool IsWholeWordMatch(string text, int index, int length) {
        if (length <= 0) return true;
        if (IsWordChar(text[index])) {
            if (index > 0 && IsWordChar(text[index - 1])) {
                return false;
            }
        }
        int rightIdx = index + length - 1;
        if (IsWordChar(text[rightIdx])) {
            if (rightIdx + 1 < text.Length && IsWordChar(text[rightIdx + 1])) {
                return false;
            }
        }
        return true;
    }

    public static bool ContainsWholeWord(string text, string token) {
        if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(token)) return false;
        int startIndex = 0;
        while (startIndex <= text.Length - token.Length) {
            int found = text.IndexOf(token, startIndex, StringComparison.OrdinalIgnoreCase);
            if (found < 0) return false;
            if (IsWholeWordMatch(text, found, token.Length)) return true;
            startIndex = found + Math.Max(1, token.Length);
        }
        return false;
    }

    public static int IndexOfInRange(string text, string token, int rangeStart, int rangeEnd) {
        if (string.IsNullOrEmpty(token)) return rangeStart;
        int len = rangeEnd - rangeStart;
        if (len < token.Length) return -1;
        return text.IndexOf(token, rangeStart, len, StringComparison.OrdinalIgnoreCase);
    }

    public static bool ContainsWholeWordInRange(string text, string token, int rangeStart, int rangeEnd) {
        if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(token)) return false;
        int currentStart = rangeStart;
        int maxStart = rangeEnd - token.Length;
        while (currentStart <= maxStart) {
            int count = rangeEnd - currentStart;
            int found = text.IndexOf(token, currentStart, count, StringComparison.OrdinalIgnoreCase);
            if (found < 0) return false;
            if (IsWholeWordMatch(text, found, token.Length)) return true;
            currentStart = found + Math.Max(1, token.Length);
        }
        return false;
    }

    public static bool ContainsTokensOnSameLine(string text, string[] tokens, bool matchWholeWord) {
        if (string.IsNullOrEmpty(text) || tokens == null || tokens.Length == 0) return false;
        if (tokens.Length == 1) {
            return matchWholeWord ? ContainsWholeWord(text, tokens[0]) : text.IndexOf(tokens[0], StringComparison.OrdinalIgnoreCase) >= 0;
        }

        // Pick longest token as primary anchor
        int anchorIdx = 0;
        int maxLen = -1;
        for (int i = 0; i < tokens.Length; i++) {
            if (tokens[i].Length > maxLen) {
                maxLen = tokens[i].Length;
                anchorIdx = i;
            }
        }
        string anchor = tokens[anchorIdx];

        int startSearch = 0;
        while (startSearch <= text.Length - anchor.Length) {
            int found = text.IndexOf(anchor, startSearch, StringComparison.OrdinalIgnoreCase);
            if (found < 0) return false;

            if (matchWholeWord && !IsWholeWordMatch(text, found, anchor.Length)) {
                startSearch = found + Math.Max(1, anchor.Length);
                continue;
            }

            int lineStart = text.LastIndexOf('\n', found);
            lineStart = (lineStart < 0) ? 0 : lineStart + 1;

            int lineEnd = text.IndexOf('\n', found + anchor.Length);
            int nextSearchStart;
            if (lineEnd < 0) {
                lineEnd = text.Length;
                nextSearchStart = text.Length + 1;
            } else {
                nextSearchStart = lineEnd + 1;
                if (lineEnd > lineStart && text[lineEnd - 1] == '\r') {
                    lineEnd--;
                }
            }

            bool allOnLine = true;
            for (int i = 0; i < tokens.Length; i++) {
                if (i == anchorIdx) continue;
                string tok = tokens[i];
                if (string.IsNullOrEmpty(tok)) continue;

                if (matchWholeWord) {
                    if (!ContainsWholeWordInRange(text, tok, lineStart, lineEnd)) {
                        allOnLine = false;
                        break;
                    }
                } else {
                    if (IndexOfInRange(text, tok, lineStart, lineEnd) < 0) {
                        allOnLine = false;
                        break;
                    }
                }
            }

            if (allOnLine) {
                return true;
            }

            startSearch = nextSearchStart;
        }

        return false;
    }

    public static List<SearchResultItemV2> Search(string rootPath, string[] tokens, bool filterByDate, DateTime minDate, string[] extensions, bool matchWholeWord, bool matchSameLine) {
        var results = new ConcurrentBag<SearchResultItemV2>();
        if (string.IsNullOrWhiteSpace(rootPath) || !Directory.Exists(rootPath)) {
            return new List<SearchResultItemV2>();
        }

        if (extensions == null || extensions.Length == 0) {
            extensions = new string[] { "*.ps1", "*.md" };
        }

        var normalizedExts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool hasAllFiles = false;
        foreach (var ext in extensions) {
            if (string.IsNullOrWhiteSpace(ext)) continue;
            string t = ext.Trim();
            if (t == "*" || t == "*.*") {
                hasAllFiles = true;
                break;
            }
            if (t.StartsWith("*.")) {
                normalizedExts.Add(t);
            } else if (t.StartsWith(".")) {
                normalizedExts.Add("*" + t);
            } else {
                normalizedExts.Add("*." + t);
            }
        }

        if (hasAllFiles || normalizedExts.Count == 0) {
            normalizedExts.Clear();
            normalizedExts.Add("*.*");
        }

        var fileSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var ext in normalizedExts) {
            try {
                foreach (var f in Directory.EnumerateFiles(rootPath, ext, SearchOption.AllDirectories)) {
                    fileSet.Add(f);
                }
            } catch {}
        }

        bool hasTokens = tokens != null && tokens.Length > 0;

        Parallel.ForEach(fileSet, new ParallelOptions { MaxDegreeOfParallelism = Environment.ProcessorCount }, file => {
            try {
                var fileInfo = new FileInfo(file);
                if (filterByDate && fileInfo.LastWriteTime < minDate) {
                    return;
                }

                if (hasTokens) {
                    if (fileInfo.Length > 25 * 1024 * 1024) {
                        return;
                    }
                    string content = File.ReadAllText(file);
                    // Remove the certificate / digital signature block to avoid false base64 matches
                    int sigIdx = content.IndexOf("# SIG # Begin signature block", StringComparison.OrdinalIgnoreCase);
                    string searchContent = (sigIdx >= 0) ? content.Substring(0, sigIdx) : content;

                    // "ALL" condition - every given token must occur in the file (content or file name)
                    for (int i = 0; i < tokens.Length; i++) {
                        bool inContent = matchWholeWord
                            ? ContainsWholeWord(searchContent, tokens[i])
                            : searchContent.IndexOf(tokens[i], StringComparison.OrdinalIgnoreCase) >= 0;
                        bool inName = matchWholeWord
                            ? ContainsWholeWord(fileInfo.Name, tokens[i])
                            : fileInfo.Name.IndexOf(tokens[i], StringComparison.OrdinalIgnoreCase) >= 0;
                        if (!inContent && !inName) {
                            return;
                        }
                    }

                    if (matchSameLine && tokens.Length > 1) {
                        // Check if file name contains all tokens
                        bool nameHasAll = true;
                        for (int i = 0; i < tokens.Length; i++) {
                            bool inName = matchWholeWord
                                ? ContainsWholeWord(fileInfo.Name, tokens[i])
                                : fileInfo.Name.IndexOf(tokens[i], StringComparison.OrdinalIgnoreCase) >= 0;
                            if (!inName) { nameHasAll = false; break; }
                        }
                        if (!nameHasAll) {
                            if (!ContainsTokensOnSameLine(searchContent, tokens, matchWholeWord)) {
                                return;
                            }
                        }
                    }
                }

                string relPath = file.StartsWith(rootPath, StringComparison.OrdinalIgnoreCase)
                    ? file.Substring(rootPath.Length).TrimStart(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
                    : fileInfo.Name;

                var item = new SearchResultItemV2();
                item.FullPath = fileInfo.FullName;
                item.FileName = fileInfo.Name;
                item.RelativePath = relPath;
                item.Extension = fileInfo.Extension.ToLowerInvariant();
                item.Length = fileInfo.Length;
                item.LastWriteTime = fileInfo.LastWriteTime;
                results.Add(item);
            } catch {}
        });

        var res = new List<SearchResultItemV2>(results);
        res.Sort((a, b) => string.Compare(a.RelativePath, b.RelativePath, StringComparison.OrdinalIgnoreCase));
        return res;
    }

    public static List<SearchResultItemV2> Search(string rootPath, string[] tokens, bool filterByDate, DateTime minDate, string[] extensions, bool matchWholeWord) {
        return Search(rootPath, tokens, filterByDate, minDate, extensions, matchWholeWord, false);
    }

    public static List<SearchResultItemV2> Search(string rootPath, string[] tokens, bool filterByDate, DateTime minDate, string[] extensions) {
        return Search(rootPath, tokens, filterByDate, minDate, extensions, false, false);
    }

    public static List<SearchResultItemV2> Search(string rootPath, string[] tokens, bool filterModifiedLast5Days, int daysFilter, string[] extensions) {
        DateTime minDate = filterModifiedLast5Days ? DateTime.Today.AddDays(-daysFilter) : DateTime.MinValue;
        return Search(rootPath, tokens, filterModifiedLast5Days, minDate, extensions, false, false);
    }

    public static List<MatchLocationV2> FindMatches(string content, string[] tokens, bool matchWholeWord, bool matchSameLine) {
        var list = new List<MatchLocationV2>();
        if (string.IsNullOrEmpty(content) || tokens == null || tokens.Length == 0) {
            return list;
        }

        // Skip the digital signature block when searching for matches
        int sigIdx = content.IndexOf("# SIG # Begin signature block", StringComparison.OrdinalIgnoreCase);
        string searchContent = (sigIdx >= 0) ? content.Substring(0, sigIdx) : content;

        var lineOffsets = new List<int>();
        lineOffsets.Add(0);
        for (int i = 0; i < searchContent.Length; i++) {
            if (searchContent[i] == '\n') {
                lineOffsets.Add(i + 1);
            }
        }

        var distinctTokens = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var t in tokens) {
            if (!string.IsNullOrEmpty(t)) distinctTokens.Add(t);
        }

        var tokensOnLine = new Dictionary<int, HashSet<string>>();

        foreach (var token in distinctTokens) {
            int startIndex = 0;
            while (startIndex <= searchContent.Length - token.Length) {
                int found = searchContent.IndexOf(token, startIndex, StringComparison.OrdinalIgnoreCase);
                if (found < 0) break;

                if (!matchWholeWord || IsWholeWordMatch(searchContent, found, token.Length)) {
                    int line = 1;
                    for (int l = lineOffsets.Count - 1; l >= 0; l--) {
                        if (found >= lineOffsets[l]) {
                            line = l + 1;
                            break;
                        }
                    }

                    var loc = new MatchLocationV2();
                    loc.Index = found;
                    loc.Length = token.Length;
                    loc.LineNumber = line;
                    loc.Token = token;
                    list.Add(loc);

                    HashSet<string> lineToks;
                    if (!tokensOnLine.TryGetValue(line, out lineToks)) {
                        lineToks = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                        tokensOnLine[line] = lineToks;
                    }
                    lineToks.Add(token);
                }

                startIndex = found + Math.Max(1, token.Length);
            }
        }

        if (matchSameLine && distinctTokens.Count > 1) {
            var qualifyingLines = new HashSet<int>();
            foreach (var kvp in tokensOnLine) {
                if (kvp.Value.Count >= distinctTokens.Count) {
                    qualifyingLines.Add(kvp.Key);
                }
            }
            list.RemoveAll(m => !qualifyingLines.Contains(m.LineNumber));
        }

        list.Sort((a, b) => a.Index.CompareTo(b.Index));
        return list;
    }

    public static List<MatchLocationV2> FindMatches(string content, string[] tokens, bool matchWholeWord) {
        return FindMatches(content, tokens, matchWholeWord, false);
    }

    public static List<MatchLocationV2> FindMatches(string content, string[] tokens) {
        return FindMatches(content, tokens, false, false);
    }
}
"@
    Add-Type -TypeDefinition $csharpEngine -Language CSharp
}

# ── 4. Configuration and Persistence (config.json) ──────────────────────────
$script:ScriptDir = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    'D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher'
}
$script:ConfigFile = Join-Path $script:ScriptDir 'config.json'

function Get-AppConfig {
    $cfg = [PSCustomObject]@{
        SearchFolder            = 'D:\Skrypty'
        FileExtensions          = @('*.ps1', '*.md')
        FilterModifiedSince     = $null
        FilterModifiedLast5Days = $false
        DaysModifiedFilter      = 5
        SearchInSubfolders      = $true
        LastSearchQuery         = ''
        AutoExpandTree          = $true
        FontSize                = 13
        Theme                   = 'Dark'
        Language                = 'en'
        MatchWholeWord          = $false
        MatchSameLine           = $false
        SearchDebounceMs        = 750
    }

    if (Test-Path -LiteralPath $script:ConfigFile) {
        try {
            $saved = Get-Content -LiteralPath $script:ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($saved.SearchFolder) { $cfg.SearchFolder = $saved.SearchFolder }
            if ($saved.FilterModifiedSince) {
                try { $cfg.FilterModifiedSince = [DateTime]::Parse($saved.FilterModifiedSince) } catch { $cfg.FilterModifiedSince = $null }
            }
            if ($null -ne $saved.FilterModifiedLast5Days) { $cfg.FilterModifiedLast5Days = [bool]$saved.FilterModifiedLast5Days }
            if ($saved.DaysModifiedFilter) { $cfg.DaysModifiedFilter = [int]$saved.DaysModifiedFilter }
            if ($null -ne $saved.SearchInSubfolders) { $cfg.SearchInSubfolders = [bool]$saved.SearchInSubfolders }
            if ($saved.LastSearchQuery) { $cfg.LastSearchQuery = [string]$saved.LastSearchQuery }
            if ($null -ne $saved.AutoExpandTree) { $cfg.AutoExpandTree = [bool]$saved.AutoExpandTree }
            if ($saved.FileExtensions) { $cfg.FileExtensions = @($saved.FileExtensions) }
            if ($saved.Language) { $cfg.Language = [string]$saved.Language }
            if ($null -ne $saved.MatchWholeWord) { $cfg.MatchWholeWord = [bool]$saved.MatchWholeWord }
            if ($null -ne $saved.MatchSameLine) { $cfg.MatchSameLine = [bool]$saved.MatchSameLine }
            if ($saved.SearchDebounceMs) { $cfg.SearchDebounceMs = [int]$saved.SearchDebounceMs }
            if ($saved.Theme -and $saved.Theme -in @('Dark','Light')) { $cfg.Theme = [string]$saved.Theme }
        } catch {
            Write-Warning "Failed to read config.json: $_"
        }
    }
    return $cfg
}

function Save-AppConfig {
    param(
        [string]$SearchFolder,
        [Nullable[DateTime]]$FilterModifiedSince = $null,
        [bool]$FilterModifiedLast5Days = $false,
        [int]$DaysModifiedFilter = 5,
        [string[]]$FileExtensions = @('*.ps1', '*.md'),
        [string]$LastSearchQuery = '',
        [string]$Language = '',
        [string]$Theme = '',
        [bool]$MatchWholeWord = $false,
        [bool]$MatchSameLine = $false,
        [int]$SearchDebounceMs = 0
    )
    $langToSave     = if ($Language)         { $Language }         elseif ($script:Config -and $script:Config.Language)  { $script:Config.Language }  else { 'en' }
    $themeToSave    = if ($Theme -in @('Dark','Light')) { $Theme } elseif ($script:CurrentTheme) { $script:CurrentTheme } else { 'Dark' }
    $debounceToSave = if ($SearchDebounceMs -gt 0) { $SearchDebounceMs } elseif ($script:Config -and $script:Config.SearchDebounceMs) { $script:Config.SearchDebounceMs } else { 750 }
    $cfg = [PSCustomObject]@{
        SearchFolder            = $SearchFolder
        FileExtensions          = $FileExtensions
        FilterModifiedSince     = if ($FilterModifiedSince) { $FilterModifiedSince.ToString('yyyy-MM-dd') } else { $null }
        FilterModifiedLast5Days = $FilterModifiedLast5Days
        DaysModifiedFilter      = $DaysModifiedFilter
        SearchInSubfolders      = $true
        LastSearchQuery         = $LastSearchQuery
        AutoExpandTree          = $true
        FontSize                = 13
        Theme                   = $themeToSave
        Language                = $langToSave
        MatchWholeWord          = $MatchWholeWord
        MatchSameLine           = $MatchSameLine
        SearchDebounceMs        = $debounceToSave
    }
    try {
        $json = $cfg | ConvertTo-Json -Depth 4
        $utf8Bom = [System.Text.UTF8Encoding]::new($true)
        [System.IO.File]::WriteAllText($script:ConfigFile, $json, $utf8Bom)
    } catch {
        Write-Warning "Failed to write config.json: $_"
    }
}

$script:Config = Get-AppConfig

# ── Localization: Multi-language support (EN/DE/PL) via external language.json
$script:LanguageFile = Join-Path $script:ScriptDir 'language.json'

function Import-LanguageCatalog {
    [CmdletBinding()]
    param()

    $script:LanguagesCatalog = [ordered]@{}

    if (Test-Path -LiteralPath $script:LanguageFile) {
        try {
            $raw = [System.IO.File]::ReadAllText($script:LanguageFile, [System.Text.Encoding]::UTF8)
            $parsed = $raw | ConvertFrom-Json
            if ($parsed.Languages) {
                foreach ($prop in $parsed.Languages.PSObject.Properties) {
                    $code = $prop.Name.ToLower()
                    $langData = $prop.Value
                    $disp = if ($langData.DisplayName) { [string]$langData.DisplayName } else { $code.ToUpper() }
                    $strMap = @{}
                    if ($langData.Strings) {
                        foreach ($sProp in $langData.Strings.PSObject.Properties) {
                            $strMap[$sProp.Name] = [string]$sProp.Value
                        }
                    }
                    $script:LanguagesCatalog[$code] = [PSCustomObject]@{
                        Code        = $code
                        DisplayName = $disp
                        Strings     = $strMap
                    }
                }
            }
        } catch {
            Write-Warning "Failed to parse language.json: $_"
        }
    }

    # Ensure a minimal English fallback always exists so the UI never breaks
    if (-not $script:LanguagesCatalog.Contains('en')) {
        $script:LanguagesCatalog['en'] = [PSCustomObject]@{
            Code        = 'en'
            DisplayName = 'English'
            Strings     = @{}
        }
    }
}

Import-LanguageCatalog

function Get-UiString {
    param([string]$Key, [string]$Default = '')
    if ($script:Strings -and $script:Strings.Contains($Key)) { return $script:Strings[$Key] }
    return $Default
}

# ── 5. UI Definition (XAML - Dark/Light Switchable Theme) ────────────────────
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="FastSearcher — Fast Search Tool"
        Height="840" Width="1200" MinHeight="650" MinWidth="950"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource BgWindow}" Foreground="{DynamicResource TextPrimary}"
        FontFamily="Segoe UI Variable, Segoe UI, sans-serif">

    <Window.Resources>
        <!-- ── Theme-switchable brush palette (colors updated at runtime by Apply-Theme) ─────── -->
        <!-- Background layers -->
        <SolidColorBrush x:Key="BgWindow"          Color="#0F172A"/>
        <SolidColorBrush x:Key="BgPanel"           Color="#1E293B"/>
        <SolidColorBrush x:Key="BgPanelDark"       Color="#162032"/>
        <SolidColorBrush x:Key="BgCode"            Color="#0A0F1D"/>
        <!-- Buttons / interactive elements -->
        <SolidColorBrush x:Key="BtnSecondary"      Color="#334155"/>
        <!-- Borders -->
        <SolidColorBrush x:Key="BrdrMain"          Color="#334155"/>
        <SolidColorBrush x:Key="BrdrHover"         Color="#475569"/>
        <!-- Text -->
        <SolidColorBrush x:Key="TextPrimary"       Color="#F8FAFC"/>
        <SolidColorBrush x:Key="TextCode"          Color="#E2E8F0"/>
        <SolidColorBrush x:Key="TextSecondary"     Color="#94A3B8"/>
        <SolidColorBrush x:Key="TextMuted"         Color="#64748B"/>
        <SolidColorBrush x:Key="TextHighlight"     Color="#38BDF8"/>
        <SolidColorBrush x:Key="TextSubtitle"      Color="#BAE6FD"/>
        <!-- Accent palette -->
        <SolidColorBrush x:Key="AccentBlue"        Color="#2563EB"/>
        <SolidColorBrush x:Key="AccentBlueHover"   Color="#1D4ED8"/>
        <SolidColorBrush x:Key="AccentBlueMid"     Color="#60A5FA"/>
        <SolidColorBrush x:Key="AccentBlueDark"    Color="#1E3A8A"/>
        <SolidColorBrush x:Key="AccentBluePale"    Color="#93C5FD"/>
        <SolidColorBrush x:Key="AccentBlueMedium"  Color="#3B82F6"/>
        <SolidColorBrush x:Key="AccentGreen"       Color="#10B981"/>
        <SolidColorBrush x:Key="CaretCol"          Color="#38BDF8"/>

        <!-- SystemColors overrides for TreeView &amp; standard controls -->
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}"                      Color="#2563EB"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}"                  Color="#FFFFFF"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}"     Color="#1E3A8A"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#FFFFFF"/>

        <!-- TextBox -->
        <Style TargetType="TextBox">
            <Setter Property="Background"          Value="{DynamicResource BgPanel}"/>
            <Setter Property="Foreground"          Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush"         Value="{DynamicResource BrdrMain}"/>
            <Setter Property="BorderThickness"     Value="1"/>
            <Setter Property="Padding"             Value="8,5"/>
            <Setter Property="FontSize"            Value="13"/>
            <Setter Property="CaretBrush"          Value="{DynamicResource CaretCol}"/>
        </Style>

        <!-- Button (accent blue default, secondary variant overrides Background inline) -->
        <Style TargetType="Button">
            <Setter Property="Background"          Value="{DynamicResource AccentBlue}"/>
            <Setter Property="Foreground"          Value="#FFFFFF"/>
            <Setter Property="BorderThickness"     Value="0"/>
            <Setter Property="Padding"             Value="12,6"/>
            <Setter Property="FontSize"            Value="12"/>
            <Setter Property="FontWeight"          Value="SemiBold"/>
            <Setter Property="Cursor"              Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- CheckBox -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground"              Value="{DynamicResource TextPrimary}"/>
            <Setter Property="FontSize"                Value="12"/>
            <Setter Property="Cursor"                  Value="Hand"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <!-- ContextMenu -->
        <Style TargetType="{x:Type ContextMenu}">
            <Setter Property="Background"      Value="{DynamicResource BgPanel}"/>
            <Setter Property="Foreground"      Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush"     Value="{DynamicResource BrdrMain}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding"         Value="4,4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ContextMenu}">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="6"
                                Padding="{TemplateBinding Padding}"
                                SnapsToDevicePixels="True">
                            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- MenuItem (context menus & dropdown presets) -->
        <Style TargetType="{x:Type MenuItem}">
            <Setter Property="Background"          Value="Transparent"/>
            <Setter Property="Foreground"          Value="{DynamicResource TextPrimary}"/>
            <Setter Property="FontSize"            Value="12"/>
            <Setter Property="Padding"             Value="10,5"/>
            <Setter Property="Cursor"              Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type MenuItem}">
                        <Border x:Name="ItemBorder"
                                Background="{TemplateBinding Background}"
                                CornerRadius="4"
                                Padding="{TemplateBinding Padding}"
                                Margin="1,1"
                                SnapsToDevicePixels="True">
                            <ContentPresenter ContentSource="Header"
                                              HorizontalAlignment="Left"
                                              VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="ItemBorder" Property="Background" Value="{DynamicResource AccentBlue}"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="{DynamicResource TextMuted}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Separator -->
        <Style TargetType="{x:Type Separator}">
            <Setter Property="Background" Value="{DynamicResource BrdrMain}"/>
            <Setter Property="Margin"     Value="4,3"/>
            <Setter Property="Height"     Value="1"/>
        </Style>

        <!-- DatePicker &amp; Calendar -->
        <Style TargetType="{x:Type DatePicker}">
            <Setter Property="Background"          Value="{DynamicResource BgPanel}"/>
            <Setter Property="Foreground"          Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush"         Value="{DynamicResource BrdrMain}"/>
            <Setter Property="BorderThickness"     Value="1"/>
            <Setter Property="FontSize"            Value="12"/>
        </Style>
        <Style TargetType="{x:Type DatePickerTextBox}">
            <Setter Property="Background"              Value="{DynamicResource BgPanel}"/>
            <Setter Property="Foreground"              Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderThickness"         Value="0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Padding"                 Value="4,1"/>
            <Setter Property="CaretBrush"              Value="{DynamicResource CaretCol}"/>
        </Style>
        <Style TargetType="{x:Type Calendar}">
            <Setter Property="Background"  Value="{DynamicResource BgPanel}"/>
            <Setter Property="Foreground"  Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BrdrMain}"/>
        </Style>
        <Style TargetType="{x:Type CalendarItem}">
            <Setter Property="Background"  Value="{DynamicResource BgPanel}"/>
            <Setter Property="Foreground"  Value="{DynamicResource TextPrimary}"/>
        </Style>
        <Style TargetType="{x:Type CalendarDayButton}">
            <Setter Property="Foreground"  Value="{DynamicResource TextPrimary}"/>
        </Style>
        <Style TargetType="{x:Type CalendarButton}">
            <Setter Property="Foreground"  Value="{DynamicResource TextPrimary}"/>
        </Style>

        <!-- Expander ToggleButton Style (tree chevron) -->
        <Style x:Key="ExpandCollapseToggleStyle" TargetType="{x:Type ToggleButton}">
            <Setter Property="Focusable" Value="False"/>
            <Setter Property="Width"     Value="16"/>
            <Setter Property="Height"    Value="16"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Border Width="16" Height="16" Background="Transparent" Padding="3">
                            <Path x:Name="ExpandPath" Fill="{DynamicResource TextSecondary}" Data="M 0 0 L 5 4 L 0 8 Z"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="RenderTransform" TargetName="ExpandPath">
                                    <Setter.Value>
                                        <RotateTransform Angle="90" CenterX="2.5" CenterY="4"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Fill" TargetName="ExpandPath" Value="{DynamicResource TextHighlight}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Fill" TargetName="ExpandPath" Value="{DynamicResource TextHighlight}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- TreeView base -->
        <Style TargetType="TreeView">
            <Setter Property="Background"      Value="{DynamicResource BgWindow}"/>
            <Setter Property="Foreground"      Value="{DynamicResource TextPrimary}"/>
            <Setter Property="BorderBrush"     Value="{DynamicResource BrdrMain}"/>
            <Setter Property="BorderThickness" Value="1"/>
        </Style>

        <!-- Modern TreeViewItem Style - persistent vibrant highlight (active AND inactive) -->
        <Style x:Key="ModernTreeViewItemStyle" TargetType="{x:Type TreeViewItem}">
            <Setter Property="Background"                Value="Transparent"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="VerticalContentAlignment"   Value="Center"/>
            <Setter Property="Padding"   Value="4,2"/>
            <Setter Property="Foreground" Value="{DynamicResource TextPrimary}"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="IsExpanded" Value="{Binding IsExpanded, Mode=TwoWay}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type TreeViewItem}">
                        <Grid>
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition MinWidth="19" Width="Auto"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition/>
                            </Grid.RowDefinitions>
                            <ToggleButton x:Name="Expander"
                                          Style="{StaticResource ExpandCollapseToggleStyle}"
                                          IsChecked="{Binding Path=IsExpanded, RelativeSource={RelativeSource TemplatedParent}}"
                                          ClickMode="Press"/>
                            <Border Name="Bd" Grid.Column="1"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="1"
                                    CornerRadius="4"
                                    Padding="{TemplateBinding Padding}"
                                    Margin="0,1,4,1"
                                    SnapsToDevicePixels="True">
                                <ContentPresenter x:Name="PART_Header"
                                                  ContentSource="Header"
                                                  HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
                            </Border>
                            <ItemsPresenter x:Name="ItemsHost" Grid.Row="1" Grid.Column="1"/>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsExpanded" Value="false">
                                <Setter Property="Visibility" TargetName="ItemsHost" Value="Collapsed"/>
                            </Trigger>
                            <Trigger Property="HasItems" Value="false">
                                <Setter Property="Visibility" TargetName="Expander" Value="Hidden"/>
                            </Trigger>
                            <!-- Hover state for unselected items -->
                            <MultiTrigger>
                                <MultiTrigger.Conditions>
                                    <Condition Property="IsMouseOver" SourceName="Bd" Value="True"/>
                                    <Condition Property="IsSelected" Value="False"/>
                                </MultiTrigger.Conditions>
                                <Setter Property="Background"  TargetName="Bd" Value="{DynamicResource BgPanel}"/>
                                <Setter Property="BorderBrush" TargetName="Bd" Value="{DynamicResource BrdrHover}"/>
                            </MultiTrigger>
                            <!-- Selected state: always bright blue regardless of focus state -->
                            <Trigger Property="IsSelected" Value="True">
                                <Setter Property="Background"  TargetName="Bd" Value="{DynamicResource AccentBlue}"/>
                                <Setter Property="BorderBrush" TargetName="Bd" Value="{DynamicResource AccentBlueMid}"/>
                                <Setter Property="Foreground"  Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Implicit style ensuring all TreeViewItems in this window inherit ModernTreeViewItemStyle -->
        <Style TargetType="{x:Type TreeViewItem}" BasedOn="{StaticResource ModernTreeViewItemStyle}"/>

        <!-- Node template - ItemContainerStyle explicitly set for hierarchical children -->
        <HierarchicalDataTemplate x:Key="NodeTemplate"
                                  ItemsSource="{Binding Children}"
                                  ItemContainerStyle="{StaticResource ModernTreeViewItemStyle}">
            <StackPanel Orientation="Horizontal" Margin="2,2">
                <TextBlock Text="{Binding Icon}" Margin="0,0,6,0" FontSize="13" VerticalAlignment="Center"/>
                <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="12.5" VerticalAlignment="Center"/>
                <TextBlock Text="{Binding Subtitle}" Margin="8,0,0,0" Foreground="{DynamicResource TextSubtitle}" FontSize="11" VerticalAlignment="Center"/>
            </StackPanel>
        </HierarchicalDataTemplate>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Top Bar (Header, Search, Filters) -->
            <RowDefinition Height="*"/>    <!-- Main Splitter Area (Tree + Preview) -->
            <RowDefinition Height="Auto"/> <!-- Status Bar -->
        </Grid.RowDefinitions>

        <!-- ── TOP BAR: MANAGEMENT AND SEARCH ──────────────────────────────── -->
        <Border Grid.Row="0" Background="{DynamicResource BgPanelDark}" BorderBrush="{DynamicResource BrdrMain}" BorderThickness="0,0,0,1" Padding="14,10">
            <Grid>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/> <!-- Title & Stats row -->
                    <RowDefinition Height="Auto"/> <!-- Folder row -->
                    <RowDefinition Height="Auto"/> <!-- Search Box row -->
                    <RowDefinition Height="Auto"/> <!-- Filters row -->
                </Grid.RowDefinitions>

                <!-- Row 0: App Header -->
                <Grid Grid.Row="0" Margin="0,0,0,8">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <TextBlock Text="⚡ FastSearcher" FontSize="17" FontWeight="Bold" Foreground="{DynamicResource TextHighlight}"/>
                        <Border Background="{DynamicResource BgPanel}" CornerRadius="4" Padding="6,2" Margin="10,0,0,0">
                            <TextBlock Name="lblHeaderSubtitle" Text="Ultra-Fast Script &amp; Markdown Search" FontSize="11" Foreground="{DynamicResource TextSecondary}"/>
                        </Border>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <TextBlock Name="lblTopStats" Text="Ready" Foreground="{DynamicResource TextSecondary}" FontSize="11.5" Margin="0,0,12,0"/>
                        <Button Name="btnThemeToggle" Content="☀️ Light" Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}"
                                Width="90" Height="24" FontSize="11" FontWeight="Normal" Margin="0,0,10,0"/>
                        <TextBlock Name="lblLanguageLabel" Text="Language:" Foreground="{DynamicResource TextSecondary}" FontSize="11.5" VerticalAlignment="Center" Margin="0,0,4,0"/>
                        <ComboBox Name="cmbLanguage" Width="100" Height="24" FontSize="11.5" VerticalContentAlignment="Center"/>
                    </StackPanel>
                </Grid>
                <!-- Row 1: Folder Selection -->
                <Grid Grid.Row="1" Margin="0,0,0,6">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="65"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Name="lblFolderLabel" Grid.Column="0" Text="Folder:" Foreground="{DynamicResource TextSecondary}" FontSize="12.5" VerticalAlignment="Center" FontWeight="SemiBold"/>
                    <TextBox Name="txtFolder" Grid.Column="1" Height="28" Margin="0,0,6,0" VerticalContentAlignment="Center"/>
                    <Button Name="btnBrowse"      Grid.Column="2" Content="📁 Browse..."         Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="28" Margin="0,0,4,0" Padding="10,4"/>
                    <Button Name="btnSaveDefault" Grid.Column="3" Content="💾 Save as Default"  Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="28" Margin="0,0,4,0" Padding="10,4"/>
                    <Button Name="btnOpenFolder"  Grid.Column="4" Content="📂 Open"              Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="28" Padding="10,4"/>
                </Grid>

                <!-- Row 2: Search Input -->
                <Grid Grid.Row="2" Margin="0,0,0,6">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="65"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Name="lblSearchLabel" Grid.Column="0" Text="Search:" Foreground="{DynamicResource TextHighlight}" FontSize="12.5" VerticalAlignment="Center" FontWeight="Bold"/>
                    <Grid Grid.Column="1" Margin="0,0,6,0">
                        <TextBox Name="txtSearch" Height="30" FontSize="13" Padding="8,4,26,4" VerticalContentAlignment="Center"/>
                        <Button Name="btnClearSearch" Content="✕" Width="20" Height="20" HorizontalAlignment="Right" Margin="0,0,5,0"
                                Background="Transparent" Foreground="{DynamicResource TextSecondary}" FontSize="11" ToolTip="Clear query"/>
                    </Grid>
                    <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center" Margin="4,0,8,0">
                        <CheckBox Name="chkWholeWord" Content="Whole word" VerticalAlignment="Center" Margin="0,0,10,0"
                                  FontSize="12" ToolTip="Match whole words only (e.g. 'DR' will not match 'poDRill')"/>
                        <CheckBox Name="chkSameLine" Content="Same line" VerticalAlignment="Center" Margin="0,0,4,0"
                                  FontSize="12" ToolTip="All search phrases must appear on the same line"/>
                    </StackPanel>
                    <Button Name="btnSearch" Grid.Column="3" Content="🔍 Search (Enter)" Height="30" Padding="16,4" FontWeight="Bold" Margin="0,0,4,0"/>
                    <Button Name="btnReset"  Grid.Column="4" Content="↺ Reset" Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="30" Padding="10,4"/>
                </Grid>

                <!-- Row 3: Filters & Tokens Display -->
                <Grid Grid.Row="3">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <!-- Dynamic Date Filter -->
                        <TextBlock Name="lblDateFilterLabel" Text="Modified since:" Foreground="{DynamicResource TextSecondary}" FontSize="12" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <DatePicker Name="dpModifiedSince" Width="118" Height="26" Margin="0,0,3,0" FontSize="11.5"
                                    ToolTip="Filter files modified on or after this date. Leave empty for all files."/>
                        <Button Name="btnClearDate" Content="✕" Width="20" Height="26" Margin="0,0,4,0"
                                Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextSecondary}" FontSize="11"
                                ToolTip="Clear date filter (show all files)" Visibility="Collapsed"/>
                        <Button Name="btnDatePresets" Content="Presets ▾" Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="26" Padding="8,2" Margin="0,0,16,0" FontSize="11.5"
                                ToolTip="Quick date presets (Today, 24h, 5 days, 30 days, All files)"/>

                        <!-- Dynamic Extensions -->
                        <TextBlock Name="lblExtensionsLabel" Text="Extensions:" Foreground="{DynamicResource TextSecondary}" FontSize="12" VerticalAlignment="Center" Margin="0,0,6,0"/>
                        <TextBox Name="txtExtensions" Width="170" Height="26" Margin="0,0,4,0" Padding="6,2" VerticalContentAlignment="Center" FontSize="12"
                                 ToolTip="Extensions to search, separated by commas, spaces, or semicolons (e.g. *.ps1, *.md, *.sql, *.*)"/>
                        <Button Name="btnExtPresets" Content="Presets ▾" Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="26" Padding="8,2" Margin="0,0,4,0" FontSize="11.5"
                                ToolTip="Choose a preset extension pack or append extensions"/>
                        <Button Name="btnExtAll" Content="*.* All" Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Height="26" Padding="8,2" Margin="0,0,16,0" FontSize="11.5"
                                ToolTip="Toggle search across all files (*.*)" />
                        <!-- Visual tokens -->
                        <TextBlock Name="lblTokens" Text="Phrases: (none)" Foreground="{DynamicResource TextHighlight}" FontSize="11.5" VerticalAlignment="Center"/>
                    </StackPanel>
                </Grid>
            </Grid>
        </Border>

        <!-- ── MAIN SPLIT AREA (TREE + PREVIEW) ────────────────────────────── -->
        <Grid Grid.Row="1">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="380" MinWidth="260"/>
                <ColumnDefinition Width="5"/>
                <ColumnDefinition Width="*" MinWidth="450"/>
            </Grid.ColumnDefinitions>

            <!-- ── LEFT SIDE: RESULTS TREE (TREEVIEW) ────────────────────── -->
            <Grid Grid.Column="0" Background="{DynamicResource BgWindow}">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/> <!-- Treeview Header -->
                    <RowDefinition Height="*"/>    <!-- Treeview Control -->
                </Grid.RowDefinitions>

                <Border Grid.Row="0" Background="{DynamicResource BgPanel}" BorderBrush="{DynamicResource BrdrMain}" BorderThickness="0,0,0,1" Padding="10,6">
                    <Grid>
                        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                            <TextBlock Name="lblResultsHeader" Text="Results" FontWeight="Bold" FontSize="13" Foreground="{DynamicResource TextPrimary}"/>
                            <Border Background="{DynamicResource AccentBlue}" CornerRadius="8" Padding="6,1" Margin="6,0,0,0">
                                <TextBlock Name="lblResultBadge" Text="0 files" FontSize="11" Foreground="#FFFFFF" FontWeight="SemiBold"/>
                            </Border>
                        </StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button Name="btnExpandAll"   Content="⊞ Expand"   Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" FontSize="11" Padding="6,2" Margin="0,0,4,0"/>
                            <Button Name="btnCollapseAll" Content="⊟ Collapse"  Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" FontSize="11" Padding="6,2"/>
                        </StackPanel>
                    </Grid>
                </Border>


                <TreeView Name="treeResults" Grid.Row="1"
                          ItemTemplate="{StaticResource NodeTemplate}"
                          ItemContainerStyle="{StaticResource ModernTreeViewItemStyle}"
                          BorderThickness="0" Background="{DynamicResource BgWindow}"
                          VirtualizingStackPanel.IsVirtualizing="True"
                          VirtualizingStackPanel.VirtualizationMode="Recycling">
                    <TreeView.ContextMenu>
                        <ContextMenu>
                            <MenuItem Name="menuOpenFile"     Header="⚡ Open file"/>
                            <MenuItem Name="menuOpenVSCode"   Header="💻 Open in VS Code"/>
                            <MenuItem Name="menuOpenFolder"   Header="📂 Open file folder"/>
                            <Separator/>
                            <MenuItem Name="menuCopyFullPath" Header="📋 Copy full path"/>
                            <MenuItem Name="menuCopyRelPath"  Header="📄 Copy file name"/>
                        </ContextMenu>
                    </TreeView.ContextMenu>
                </TreeView>
            </Grid>

            <!-- SPLITTER BETWEEN PANELS -->
            <GridSplitter Grid.Column="1" Width="5" HorizontalAlignment="Stretch" Background="{DynamicResource BrdrMain}" Cursor="SizeWE"/>

            <!-- ── RIGHT SIDE: FILE CONTENT PREVIEW ─────────────────────────── -->
            <Grid Grid.Column="2" Background="{DynamicResource BgCode}">
                <!-- State 1: No file selected (Placeholder) -->
                <Grid Name="panelEmpty" HorizontalAlignment="Center" VerticalAlignment="Center">
                    <StackPanel HorizontalAlignment="Center">
                        <TextBlock Text="📄" FontSize="44" HorizontalAlignment="Center" Margin="0,0,0,10"/>
                        <TextBlock Name="lblEmptyTitle"    Text="Select a file from the tree on the left" FontSize="15" FontWeight="SemiBold" Foreground="{DynamicResource TextSecondary}" HorizontalAlignment="Center"/>
                        <TextBlock Name="lblEmptySubtitle" Text="Content and matches will be displayed here instantly" FontSize="12" Foreground="{DynamicResource TextMuted}" HorizontalAlignment="Center" Margin="0,4,0,0"/>
                    </StackPanel>
                </Grid>

                <!-- State 2: File display -->
                <Grid Name="panelPreview" Visibility="Collapsed">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/> <!-- File Header Card -->
                        <RowDefinition Height="*"/>    <!-- Text Preview Area -->
                    </Grid.RowDefinitions>

                    <!-- File header and actions -->
                    <Border Grid.Row="0" Background="{DynamicResource BgPanel}" BorderBrush="{DynamicResource BrdrMain}" BorderThickness="0,0,0,1" Padding="12,8">
                        <Grid>
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/> <!-- Title & Action Buttons -->
                                <RowDefinition Height="Auto"/> <!-- Path -->
                                <RowDefinition Height="Auto"/> <!-- Badges -->
                                <RowDefinition Height="Auto"/> <!-- Match Navigator -->
                            </Grid.RowDefinitions>

                            <!-- Row 0: File name and action buttons -->
                            <Grid Grid.Row="0">
                                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                    <TextBlock Name="lblFileIcon" Text="⚡" FontSize="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
                                    <TextBlock Name="lblFileName" Text="filename.ps1" FontSize="15" FontWeight="Bold" Foreground="{DynamicResource TextHighlight}" VerticalAlignment="Center"/>
                                    <Border Name="badgeExt" Background="{DynamicResource AccentBlue}" CornerRadius="3" Padding="5,1" Margin="8,0,0,0" VerticalAlignment="Center">
                                        <TextBlock Name="lblBadgeExtText" Text="PS1" FontSize="10" FontWeight="Bold" Foreground="#FFFFFF"/>
                                    </Border>
                                </StackPanel>

                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                    <Button Name="btnPreviewOpenFile"  Content="⚡ Open"       Padding="8,4" Margin="0,0,4,0"/>
                                    <Button Name="btnPreviewVSCode"    Content="💻 VS Code"    Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Padding="8,4" Margin="0,0,4,0"/>
                                    <Button Name="btnPreviewOpenDir"   Content="📂 Folder"     Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Padding="8,4" Margin="0,0,4,0"/>
                                    <Button Name="btnPreviewCopyPath"  Content="📋 Path"       Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Padding="8,4" Margin="0,0,4,0"/>
                                    <Button Name="btnPreviewCopyText"  Content="📄 Copy code"  Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" Padding="8,4"/>
                                </StackPanel>
                            </Grid>

                            <!-- Row 1: Full file path -->
                            <TextBlock Name="txtFullPath" Grid.Row="1" Text="D:\Skrypty\..." Foreground="{DynamicResource TextSecondary}" FontSize="11" Margin="0,4,0,4" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>

                            <!-- Row 2: File metadata -->
                            <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,2,0,0">
                                <Border Background="{DynamicResource BgPanelDark}" CornerRadius="3" Padding="6,2" Margin="0,0,6,0">
                                    <TextBlock Name="lblFileSize"     Text="0 KB"       FontSize="11" Foreground="{DynamicResource TextSecondary}"/>
                                </Border>
                                <Border Background="{DynamicResource BgPanelDark}" CornerRadius="3" Padding="6,2" Margin="0,0,6,0">
                                    <TextBlock Name="lblLineCount"    Text="0 lines"    FontSize="11" Foreground="{DynamicResource TextSecondary}"/>
                                </Border>
                                <Border Background="{DynamicResource BgPanelDark}" CornerRadius="3" Padding="6,2" Margin="0,0,6,0">
                                    <TextBlock Name="lblModifiedDate" Text="2026-00-00"  FontSize="11" Foreground="{DynamicResource TextSecondary}"/>
                                </Border>
                                <Border Name="borderMatchCount" Background="{DynamicResource AccentBlueDark}" CornerRadius="3" Padding="6,2" Margin="0,0,6,0">
                                    <TextBlock Name="lblMatchBadge" Text="Matches: 0" FontSize="11" Foreground="{DynamicResource AccentBluePale}" FontWeight="SemiBold"/>
                                </Border>
                            </StackPanel>

                            <!-- Row 3: Match Navigator -->
                            <Border Name="panelMatchNav" Grid.Row="3"
                                    Background="{DynamicResource BgPanelDark}"
                                    BorderBrush="{DynamicResource AccentBlueMedium}"
                                    BorderThickness="1" CornerRadius="4" Padding="8,4" Margin="0,8,0,0" Visibility="Collapsed">
                                <Grid>
                                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                                        <TextBlock Name="lblMatchNavLabel" Text="🎯 Matches in file:" FontWeight="SemiBold" Foreground="{DynamicResource TextHighlight}" FontSize="11.5" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                        <TextBlock Name="lblMatchStatus" Text="Match 1 of 3 (Line 12)" Foreground="{DynamicResource TextPrimary}" FontSize="11.5" VerticalAlignment="Center"/>
                                    </StackPanel>
                                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                                        <Button Name="btnPrevMatch" Content="▲ Previous" Background="{DynamicResource BtnSecondary}" Foreground="{DynamicResource TextPrimary}" FontSize="11" Padding="8,2" Margin="0,0,4,0"/>
                                        <Button Name="btnNextMatch" Content="▼ Next"     FontSize="11" Padding="8,2"/>
                                    </StackPanel>
                                </Grid>
                            </Border>
                        </Grid>
                    </Border>

                    <!-- Code preview editor -->
                    <TextBox Name="txtPreview" Grid.Row="1"
                             IsReadOnly="True"
                             FontFamily="Cascadia Code, Consolas, Courier New"
                             FontSize="12.5"
                             Background="{DynamicResource BgCode}" Foreground="{DynamicResource TextCode}"
                             BorderThickness="0" Padding="10"
                             VerticalScrollBarVisibility="Auto"
                             HorizontalScrollBarVisibility="Auto"
                             AcceptsReturn="True"
                             IsInactiveSelectionHighlightEnabled="True"
                             CaretBrush="{DynamicResource CaretCol}"
                             SelectionBrush="{DynamicResource AccentBlue}"/>
                </Grid>
            </Grid>
        </Grid>

        <!-- ── BOTTOM STATUS BAR ────────────────────────────────────────────── -->
        <Border Grid.Row="2" Background="{DynamicResource BgPanelDark}" BorderBrush="{DynamicResource BrdrMain}" BorderThickness="0,1,0,0" Padding="12,5">
            <Grid>
                <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Name="lblStatus" Text="Ready to search." Foreground="{DynamicResource TextSecondary}" FontSize="11.5"/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                    <TextBlock Name="lblStatusRight" Text="D:\Skrypty | UTF-8 with BOM" Foreground="{DynamicResource TextMuted}" FontSize="11"/>
                </StackPanel>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

# ── 6. Load the WPF XAML window ──────────────────────────────────────────────
$reader = [System.Xml.XmlNodeReader]::new($xaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Retrieve controls from the XAML tree
$txtFolder           = $window.FindName("txtFolder")
$btnBrowse           = $window.FindName("btnBrowse")
$btnSaveDefault      = $window.FindName("btnSaveDefault")
$btnOpenFolder       = $window.FindName("btnOpenFolder")
$btnThemeToggle      = $window.FindName("btnThemeToggle")

$txtSearch           = $window.FindName("txtSearch")
$btnClearSearch      = $window.FindName("btnClearSearch")
$chkWholeWord        = $window.FindName("chkWholeWord")
$chkSameLine         = $window.FindName("chkSameLine")
$btnSearch           = $window.FindName("btnSearch")
$btnReset            = $window.FindName("btnReset")

$lblDateFilterLabel  = $window.FindName("lblDateFilterLabel")
$dpModifiedSince     = $window.FindName("dpModifiedSince")
$btnClearDate        = $window.FindName("btnClearDate")
$btnDatePresets      = $window.FindName("btnDatePresets")
$txtExtensions       = $window.FindName("txtExtensions")
$script:txtExtensions = $txtExtensions
$btnExtPresets       = $window.FindName("btnExtPresets")
$btnExtAll           = $window.FindName("btnExtAll")
$lblTokens           = $window.FindName("lblTokens")

$treeResults         = $window.FindName("treeResults")
$lblResultBadge      = $window.FindName("lblResultBadge")
$btnExpandAll        = $window.FindName("btnExpandAll")
$btnCollapseAll      = $window.FindName("btnCollapseAll")

$panelEmpty          = $window.FindName("panelEmpty")
$panelPreview        = $window.FindName("panelPreview")
$lblFileIcon         = $window.FindName("lblFileIcon")
$lblFileName         = $window.FindName("lblFileName")
$lblBadgeExtText     = $window.FindName("lblBadgeExtText")
$txtFullPath         = $window.FindName("txtFullPath")
$lblFileSize         = $window.FindName("lblFileSize")
$lblLineCount        = $window.FindName("lblLineCount")
$lblModifiedDate     = $window.FindName("lblModifiedDate")
$lblMatchBadge       = $window.FindName("lblMatchBadge")
$borderMatchCount    = $window.FindName("borderMatchCount")

$panelMatchNav       = $window.FindName("panelMatchNav")
$lblMatchStatus      = $window.FindName("lblMatchStatus")
$btnPrevMatch        = $window.FindName("btnPrevMatch")
$btnNextMatch        = $window.FindName("btnNextMatch")
$txtPreview          = $window.FindName("txtPreview")

$btnPreviewOpenFile  = $window.FindName("btnPreviewOpenFile")
$btnPreviewVSCode    = $window.FindName("btnPreviewVSCode")
$btnPreviewOpenDir   = $window.FindName("btnPreviewOpenDir")
$btnPreviewCopyPath  = $window.FindName("btnPreviewCopyPath")
$btnPreviewCopyText  = $window.FindName("btnPreviewCopyText")

$lblStatus           = $window.FindName("lblStatus")
$lblStatusRight      = $window.FindName("lblStatusRight")
$lblTopStats         = $window.FindName("lblTopStats")
$btnThemeToggle      = $window.FindName("btnThemeToggle")

# Controls used for UI localization (labels/headers with no other logic dependency)
$lblHeaderSubtitle   = $window.FindName("lblHeaderSubtitle")
$lblLanguageLabel    = $window.FindName("lblLanguageLabel")
$cmbLanguage         = $window.FindName("cmbLanguage")
$lblFolderLabel      = $window.FindName("lblFolderLabel")
$lblSearchLabel      = $window.FindName("lblSearchLabel")
$lblExtensionsLabel  = $window.FindName("lblExtensionsLabel")
$lblResultsHeader    = $window.FindName("lblResultsHeader")
$lblEmptyTitle       = $window.FindName("lblEmptyTitle")
$lblEmptySubtitle    = $window.FindName("lblEmptySubtitle")
$lblMatchNavLabel    = $window.FindName("lblMatchNavLabel")

$menuOpenFile        = $window.FindName("menuOpenFile")
$menuOpenVSCode      = $window.FindName("menuOpenVSCode")
$menuOpenFolder      = $window.FindName("menuOpenFolder")
$menuCopyFullPath    = $window.FindName("menuCopyFullPath")
$menuCopyRelPath     = $window.FindName("menuCopyRelPath")

# ── 7. Application state variables ───────────────────────────────────────────
$script:CurrentFolder        = $script:Config.SearchFolder
$script:CurrentResults       = @()
$script:CurrentTokens        = @()
$script:CurrentMatches       = @()
$script:CurrentMatchIndex    = 0
$script:SelectedFilePath     = $null
$script:RootTreeNode         = $null
$script:PreviousExtensions   = @()
$script:CurrentTheme         = if ($script:Config.Theme -in @('Dark','Light')) { $script:Config.Theme } else { 'Dark' }

function Get-ConfiguredExtensions {
    $raw = if ($txtExtensions) { $txtExtensions.Text } else { '' }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @('*.ps1', '*.md')
    }
    
    $parts = $raw -split '[,;\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $cleanExts = [System.Collections.Generic.List[string]]::new()
    $hasStarAll = $false

    foreach ($p in $parts) {
        $trimmed = $p.Trim()
        if ($trimmed -eq '*' -or $trimmed -eq '*.*') {
            $hasStarAll = $true
            continue
        }
        if ($trimmed.StartsWith('*.')) {
            $cleanExts.Add($trimmed.ToLowerInvariant())
        } elseif ($trimmed.StartsWith('.')) {
            $cleanExts.Add("*$($trimmed.ToLowerInvariant())")
        } else {
            $cleanExts.Add("*.$($trimmed.ToLowerInvariant())")
        }
    }

    if ($hasStarAll) {
        return @('*.*')
    }

    $unique = @($cleanExts | Select-Object -Unique)
    if ($unique.Count -eq 0) {
        return @('*.ps1', '*.md')
    }
    return $unique
}

function Set-ConfiguredExtensions([string[]]$exts) {
    if ($null -eq $exts -or $exts.Count -eq 0) {
        $txtExtensions.Text = '*.ps1, *.md'
    } else {
        $txtExtensions.Text = ($exts -join ', ')
    }
    Update-ExtAllButtonState
}

function Update-ExtAllButtonState {
    if (-not $btnExtAll -or -not $txtExtensions) { return }
    $exts = Get-ConfiguredExtensions
    $isAll = ($exts.Count -eq 1 -and $exts[0] -eq '*.*')
    if ($isAll) {
        # Accent blue background with white text when *.* is active
        $btnExtAll.Background = $window.Resources['AccentBlue']
        $btnExtAll.Foreground = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Colors]::White)
    } else {
        # Secondary button colours (shared brush objects — auto-update when Apply-Theme runs)
        $btnExtAll.Background = $window.Resources['BtnSecondary']
        $btnExtAll.Foreground = $window.Resources['TextPrimary']
    }
}

# ── Theme palettes (colors updated at runtime by Apply-Theme) ─────────────────
$script:DarkTheme = [ordered]@{
    BgWindow         = '#0F172A'
    BgPanel          = '#1E293B'
    BgPanelDark      = '#162032'
    BgCode           = '#0A0F1D'
    BtnSecondary     = '#334155'
    BrdrMain         = '#334155'
    BrdrHover        = '#475569'
    TextPrimary      = '#F8FAFC'
    TextCode         = '#E2E8F0'
    TextSecondary    = '#94A3B8'
    TextMuted        = '#64748B'
    TextHighlight    = '#38BDF8'
    TextSubtitle     = '#BAE6FD'
    AccentBlue       = '#2563EB'
    AccentBlueHover  = '#1D4ED8'
    AccentBlueMid    = '#60A5FA'
    AccentBlueDark   = '#1E3A8A'
    AccentBluePale   = '#93C5FD'
    AccentBlueMedium = '#3B82F6'
    AccentGreen      = '#10B981'
    CaretCol         = '#38BDF8'
}

$script:LightTheme = [ordered]@{
    BgWindow         = '#F8FAFC'
    BgPanel          = '#FFFFFF'
    BgPanelDark      = '#F1F5F9'
    BgCode           = '#FFFFFF'
    BtnSecondary     = '#E2E8F0'
    BrdrMain         = '#CBD5E1'
    BrdrHover        = '#94A3B8'
    TextPrimary      = '#0F172A'
    TextCode         = '#0F172A'
    TextSecondary    = '#475569'
    TextMuted        = '#64748B'
    TextHighlight    = '#2563EB'
    TextSubtitle     = '#64748B'
    AccentBlue       = '#2563EB'
    AccentBlueHover  = '#1D4ED8'
    AccentBlueMid    = '#60A5FA'
    AccentBlueDark   = '#DBEAFE'
    AccentBluePale   = '#1D4ED8'
    AccentBlueMedium = '#2563EB'
    AccentGreen      = '#059669'
    CaretCol         = '#2563EB'
}

<#
.SYNOPSIS
    Switches the app between Dark and Light themes at runtime.
.DESCRIPTION
    Replaces each named SolidColorBrush in Window.Resources with the color from the
    chosen palette. Because XAML elements bind to DynamicResource, replacing the keys
    triggers an immediate, seamless repaint across the entire visual tree without
    hitting WPF Freezable read-only exceptions on frozen brushes.
    Also flips the DWM title bar dark/light attribute and persists the choice.
.PARAMETER Theme
    'Dark' or 'Light'.
#>
function Apply-Theme {
    [CmdletBinding()]
    param([ValidateSet('Dark','Light')][string]$Theme = 'Dark')

    $palette  = if ($Theme -eq 'Light') { $script:LightTheme } else { $script:DarkTheme }
    $conv     = [System.Windows.Media.ColorConverter]::new()

    # Reassign every named brush in Window.Resources with a frozen SolidColorBrush
    # Replacing the resource key triggers DynamicResource refresh across all elements
    # and avoids InvalidOperationException on Freezables that XamlReader froze automatically.
    foreach ($key in $palette.Keys) {
        $color = $conv.ConvertFromString($palette[$key])
        $brush = [System.Windows.Media.SolidColorBrush]::new($color)
        $brush.Freeze()
        $window.Resources[$key] = $brush
    }

    # Update SystemColors overrides for inactive selection
    $inactiveBg = if ($Theme -eq 'Light') { '#DBEAFE' } else { '#1E3A8A' }
    $inactiveFg = if ($Theme -eq 'Light') { '#0F172A' } else { '#FFFFFF' }
    $brushInactiveBg = [System.Windows.Media.SolidColorBrush]::new($conv.ConvertFromString($inactiveBg))
    $brushInactiveBg.Freeze()
    $window.Resources[[System.Windows.SystemColors]::InactiveSelectionHighlightBrushKey] = $brushInactiveBg

    $brushInactiveFg = [System.Windows.Media.SolidColorBrush]::new($conv.ConvertFromString($inactiveFg))
    $brushInactiveFg.Freeze()
    $window.Resources[[System.Windows.SystemColors]::InactiveSelectionHighlightTextBrushKey] = $brushInactiveFg

    $script:CurrentTheme = $Theme

    # Flip theme toggle button label
    if ($btnThemeToggle) {
        $btnThemeToggle.Content = if ($Theme -eq 'Light') { '🌙 Dark' } else { '☀️ Light' }
    }

    # Update DWM title bar appearance (works only after window is shown)
    try {
        if ($window.IsLoaded) {
            $helper  = [System.Windows.Interop.WindowInteropHelper]::new($window)
            $isDark  = if ($Theme -eq 'Light') { 0 } else { 1 }
            [DwmWindowDarkHelper]::SetTitleBarMode($helper.Handle, $isDark)
        }
    } catch {}

    # Refresh button colours that are set programmatically
    Update-ExtAllButtonState
}

# Initialize fields from configuration
$txtFolder.Text = $script:CurrentFolder
if ($script:Config.FilterModifiedSince) {
    $dpModifiedSince.SelectedDate = $script:Config.FilterModifiedSince
    if ($btnClearDate) { $btnClearDate.Visibility = [System.Windows.Visibility]::Visible }
} else {
    $dpModifiedSince.SelectedDate = $null
    if ($btnClearDate) { $btnClearDate.Visibility = [System.Windows.Visibility]::Collapsed }
}
if ($script:Config.FileExtensions -and $script:Config.FileExtensions.Count -gt 0) {
    $txtExtensions.Text = ($script:Config.FileExtensions -join ', ')
} else {
    $txtExtensions.Text = '*.ps1, *.md'
}
Update-ExtAllButtonState
if ($script:Config.LastSearchQuery) {
    $txtSearch.Text = $script:Config.LastSearchQuery
}
if ($null -ne $script:Config.MatchWholeWord) {
    $chkWholeWord.IsChecked = [bool]$script:Config.MatchWholeWord
} else {
    $chkWholeWord.IsChecked = $false
}
if ($null -ne $script:Config.MatchSameLine) {
    $chkSameLine.IsChecked = [bool]$script:Config.MatchSameLine
} else {
    $chkSameLine.IsChecked = $false
}

# Populate the language selector from the loaded catalog
foreach ($code in $script:LanguagesCatalog.Keys) {
    $langObj = $script:LanguagesCatalog[$code]
    $cbi = [System.Windows.Controls.ComboBoxItem]::new()
    $cbi.Content = $langObj.DisplayName
    $cbi.Tag = $langObj.Code
    $cmbLanguage.Items.Add($cbi) | Out-Null
}

# ── 8. GUI helper and navigation functions ───────────────────────────────────

function Get-FileCountLabel([int]$count) {
    $noun = if ($count -eq 1) {
        Get-UiString 'NounFileSingular' 'file'
    } elseif ($count -ge 2 -and $count -le 4) {
        Get-UiString 'NounFileFew' 'files'
    } else {
        Get-UiString 'NounFileMany' 'files'
    }
    return "$count $noun"
}

function Set-UiLanguage {
    [CmdletBinding()]
    param([string]$LanguageCode)

    if (-not [string]::IsNullOrWhiteSpace($LanguageCode) -and $script:LanguagesCatalog.Contains($LanguageCode.ToLower())) {
        $script:CurrentLanguage = $LanguageCode.ToLower()
    } elseif (-not $script:CurrentLanguage) {
        $script:CurrentLanguage = 'en'
    }

    $langObj = $script:LanguagesCatalog[$script:CurrentLanguage]
    $script:Strings = if ($langObj -and $langObj.Strings) { $langObj.Strings } else { @{} }

    # Select the matching item in the language ComboBox without re-triggering the handler
    foreach ($item in $cmbLanguage.Items) {
        if ($item.Tag -eq $script:CurrentLanguage) { $cmbLanguage.SelectedItem = $item; break }
    }

    $window.Title             = Get-UiString 'WindowTitle' 'FastSearcher — Fast Search Tool'
    $lblHeaderSubtitle.Text    = Get-UiString 'HeaderSubtitle' 'Ultra-Fast Script & Markdown Search'
    $lblLanguageLabel.Text     = Get-UiString 'LabelLanguage' 'Language:'
    $lblFolderLabel.Text       = Get-UiString 'LabelFolder' 'Folder:'
    $btnBrowse.Content         = Get-UiString 'BtnBrowse' '📁 Browse...'
    $btnSaveDefault.Content    = Get-UiString 'BtnSaveDefault' '💾 Save as Default'
    $btnOpenFolder.Content     = Get-UiString 'BtnOpenFolder' '📂 Open'
    $lblSearchLabel.Text       = Get-UiString 'LabelSearch' 'Search:'
    $btnClearSearch.ToolTip    = Get-UiString 'TooltipClearSearch' 'Clear query'
    $btnSearch.Content         = Get-UiString 'BtnSearch' '🔍 Search (Enter)'
    $btnReset.Content          = Get-UiString 'BtnReset' '↺ Reset'
    if ($chkWholeWord) {
        $chkWholeWord.Content  = Get-UiString 'ChkWholeWord' 'Whole word'
        $chkWholeWord.ToolTip  = Get-UiString 'TooltipWholeWord' "Match whole words only (e.g. 'DR' will not match 'poDRill')"
    }
    if ($chkSameLine) {
        $chkSameLine.Content   = Get-UiString 'ChkSameLine' 'Same line'
        $chkSameLine.ToolTip   = Get-UiString 'TooltipSameLine' 'All search phrases must appear on the same line'
    }
    if ($lblDateFilterLabel) { $lblDateFilterLabel.Text  = Get-UiString 'LabelDateFilter' 'Modified since:' }
    if ($dpModifiedSince)    { $dpModifiedSince.ToolTip = Get-UiString 'TooltipDateFilter' 'Filter files modified on or after this date. Leave empty for all files.' }
    if ($btnClearDate)       { $btnClearDate.ToolTip    = Get-UiString 'TooltipClearDate' 'Clear date filter (show all files)' }
    if ($btnDatePresets)     { $btnDatePresets.Content  = Get-UiString 'BtnDatePresets' 'Presets ▾' }
    if ($btnDatePresets)     { $btnDatePresets.ToolTip  = Get-UiString 'TooltipDatePresets' 'Quick date presets (Today, 24h, 5 days, 30 days, All files)' }
    $lblExtensionsLabel.Text   = Get-UiString 'LabelExtensions' 'Extensions:'
    $txtExtensions.ToolTip     = Get-UiString 'TooltipExtensions' 'Extensions to search, separated by commas, spaces, or semicolons (e.g. *.ps1, *.md, *.sql, *.*)'
    $btnExtPresets.Content     = Get-UiString 'BtnExtPresets' 'Presets ▾'
    $btnExtPresets.ToolTip     = Get-UiString 'TooltipExtPresets' 'Choose a preset extension pack or append extensions'
    $btnExtAll.Content         = Get-UiString 'BtnExtAll' '*.* All'
    $btnExtAll.ToolTip         = Get-UiString 'TooltipExtAll' 'Toggle search across all files (*.*)'
    $lblResultsHeader.Text     = Get-UiString 'LabelResults' 'Results'
    $btnExpandAll.Content      = Get-UiString 'BtnExpandAll' '⊞ Expand'
    $btnCollapseAll.Content    = Get-UiString 'BtnCollapseAll' '⊟ Collapse'
    $menuOpenFile.Header       = Get-UiString 'MenuOpenFile' '⚡ Open file'
    $menuOpenVSCode.Header     = Get-UiString 'MenuOpenVSCode' '💻 Open in VS Code'
    $menuOpenFolder.Header     = Get-UiString 'MenuOpenFolder' '📂 Open file folder'
    $menuCopyFullPath.Header   = Get-UiString 'MenuCopyFullPath' '📋 Copy full path'
    $menuCopyRelPath.Header    = Get-UiString 'MenuCopyFileName' '📄 Copy file name'
    $lblEmptyTitle.Text        = Get-UiString 'EmptyStateTitle' 'Select a file from the tree on the left'
    $lblEmptySubtitle.Text     = Get-UiString 'EmptyStateSubtitle' 'Content and matches will be displayed here instantly'
    $btnPreviewOpenFile.Content = Get-UiString 'BtnPreviewOpen' '⚡ Open'
    $btnPreviewVSCode.Content  = Get-UiString 'BtnPreviewVSCode' '💻 VS Code'
    $btnPreviewOpenDir.Content = Get-UiString 'BtnPreviewOpenDir' '📂 Folder'
    $btnPreviewCopyPath.Content = Get-UiString 'BtnPreviewCopyPath' '📋 Path'
    $btnPreviewCopyText.Content = Get-UiString 'BtnPreviewCopyText' '📄 Copy code'
    $lblMatchNavLabel.Text     = Get-UiString 'MatchNavLabel' '🎯 Matches in file:'
    $btnPrevMatch.Content      = Get-UiString 'BtnPrevMatch' '▲ Previous'
    $btnNextMatch.Content      = Get-UiString 'BtnNextMatch' '▼ Next'

    # Refresh dynamic labels that depend on current state
    Update-TokenLabels
    $lblResultBadge.Text = Get-FileCountLabel $script:CurrentResults.Count
    if ($script:CurrentMatches -and $script:CurrentMatches.Count -gt 0) {
        Jump-ToMatch $script:CurrentMatchIndex
    }
    if (-not $script:IsWindowLoaded) {
        $lblStatus.Text = Get-UiString 'StatusReady' 'Ready to search.'
    }
}

function Update-TokenLabels {
    $rawQuery = $txtSearch.Text
    $tokens = [FastSearchEngineV2]::ParseTokens($rawQuery)
    $script:CurrentTokens = $tokens
    if ($tokens -and $tokens.Length -gt 0) {
        $formatted = ($tokens | ForEach-Object { "[$_]" }) -join ' '
        $lblTokens.Text = (Get-UiString 'TokensFormat' 'Phrases ({0}): {1}') -f $tokens.Length, $formatted
    } else {
        $lblTokens.Text = Get-UiString 'TokensNone' 'Phrases: (all files)'
    }
}

function Set-TreeExpansion($node, [bool]$expand) {
    if ($null -eq $node) { return }
    $node.IsExpanded = $expand
    foreach ($child in $node.Children) {
        if ($child.IsFolder) {
            Set-TreeExpansion $child $expand
        }
    }
}

function Jump-ToMatch([int]$targetIndex) {
    if (-not $script:CurrentMatches -or $script:CurrentMatches.Count -eq 0) { return }
    if ($targetIndex -lt 0) { $targetIndex = $script:CurrentMatches.Count - 1 }
    if ($targetIndex -ge $script:CurrentMatches.Count) { $targetIndex = 0 }

    $script:CurrentMatchIndex = $targetIndex
    $match = $script:CurrentMatches[$targetIndex]

    $lblMatchStatus.Text = (Get-UiString 'MatchStatusFormat' "Match {0} of {1} (Line {2}: '{3}')") -f ($targetIndex + 1), $script:CurrentMatches.Count, $match.LineNumber, $match.Token
    
    $null = $txtPreview.Focus()
    $txtPreview.Select($match.Index, $match.Length)
    $targetLine = [Math]::Max(0, $match.LineNumber - 4)
    $txtPreview.ScrollToLine($targetLine)
}

function Show-FilePreview($filePath) {
    if ([string]::IsNullOrWhiteSpace($filePath) -or -not (Test-Path -LiteralPath $filePath)) {
        return
    }

    $script:SelectedFilePath = $filePath
    $panelEmpty.Visibility = [System.Windows.Visibility]::Collapsed
    $panelPreview.Visibility = [System.Windows.Visibility]::Visible

    $fileInfo = [System.IO.FileInfo]::new($filePath)
    $ext = $fileInfo.Extension.ToLowerInvariant()
    
    $lblFileName.Text = $fileInfo.Name
        $lblFileIcon.Text = if ($ext -in '.ps1', '.psm1', '.psd1') { '⚡' }
        elseif ($ext -in '.md', '.markdown') { '📝' }
        elseif ($ext -eq '.sql') { '🗄️' }
        elseif ($ext -in '.json', '.yaml', '.yml', '.toml') { '📦' }
        elseif ($ext -in '.xml', '.html', '.htm', '.xaml') { '📰' }
        elseif ($ext -in '.txt', '.log', '.ini', '.cfg', '.conf') { '📋' }
        elseif ($ext -in '.csv', '.tsv') { '📊' }
        elseif ($ext -in '.cs', '.py', '.js', '.ts', '.cpp', '.c', '.h') { '💻' }
        elseif ($ext -in '.bat', '.cmd', '.sh') { '⚙️' }
        else { '📄' }
    $lblBadgeExtText.Text = if ($ext) { $ext.TrimStart('.').ToUpperInvariant() } else { 'FILE' }
    $txtFullPath.Text = $fileInfo.FullName

    $lblFileSize.Text = "{0:N1} KB" -f ($fileInfo.Length / 1024.0)
    $lblModifiedDate.Text = $fileInfo.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")

    try {
        $content = [System.IO.File]::ReadAllText($filePath)
        $txtPreview.Text = $content

        $lines = [System.Text.RegularExpressions.Regex]::Matches($content, "`n").Count + 1
        $lblLineCount.Text = "{0:N0} {1}" -f $lines, (Get-UiString 'NounLines' 'lines')

        # Search for match locations in the content
        $tokens = $script:CurrentTokens
        if ($tokens -and $tokens.Length -gt 0) {
            $isWhole = ($chkWholeWord.IsChecked -eq $true)
            $isSameLine = ($chkSameLine.IsChecked -eq $true)
            $matches = [FastSearchEngineV2]::FindMatches($content, $tokens, $isWhole, $isSameLine)
            $script:CurrentMatches = $matches

            if ($matches.Count -gt 0) {
                $panelMatchNav.Visibility = [System.Windows.Visibility]::Visible
                $borderMatchCount.Visibility = [System.Windows.Visibility]::Visible
                $lblMatchBadge.Text = (Get-UiString 'MatchBadgeFormat' 'Matches: {0}') -f $matches.Count
                Jump-ToMatch 0
            } else {
                $panelMatchNav.Visibility = [System.Windows.Visibility]::Collapsed
                $borderMatchCount.Visibility = [System.Windows.Visibility]::Collapsed
            }
        } else {
            $script:CurrentMatches = @()
            $panelMatchNav.Visibility = [System.Windows.Visibility]::Collapsed
            $borderMatchCount.Visibility = [System.Windows.Visibility]::Collapsed
        }
    } catch {
        $txtPreview.Text = (Get-UiString 'StatusReadError' 'Error reading file: {0}') -f $_
    }
}

function Invoke-ScriptSearch {
    $folder = $txtFolder.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder)) {
        [System.Windows.MessageBox]::Show((Get-UiString 'MsgFolderNotExist' "Specified folder does not exist:`n{0}") -f $folder, (Get-UiString 'MsgFolderNotExistTitle' 'FastSearcher'), "OK", "Warning")
        return
    }

    Update-TokenLabels

    # Collect configured extensions
    $exts = Get-ConfiguredExtensions
    Update-ExtAllButtonState

    $filterByDate = ($null -ne $dpModifiedSince.SelectedDate)
    $minDate = if ($filterByDate) { [DateTime]$dpModifiedSince.SelectedDate } else { [DateTime]::MinValue }
    $tokens = $script:CurrentTokens
    $isWhole = ($chkWholeWord.IsChecked -eq $true)
    $isSameLine = ($chkSameLine.IsChecked -eq $true)

    $lblStatus.Text = (Get-UiString 'StatusSearching' 'Searching files in {0}...') -f $folder
    [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait

    # swSearch: measures only the parallel C# file scan
    $swSearch = [System.Diagnostics.Stopwatch]::StartNew()
    $results = [FastSearchEngineV2]::Search($folder, $tokens, $filterByDate, $minDate, $exts, $isWhole, $isSameLine)
    $swSearch.Stop()
    # swTotal: continues through BuildTree + WPF binding to capture total GUI-blocking time
    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

    $script:CurrentResults = $results
    $count = $results.Count

    if ($count -eq 0) {
        $treeResults.ItemsSource = $null
        $script:RootTreeNode = $null
        $swTotal.Stop()
        $lblResultBadge.Text = Get-FileCountLabel 0
        $lblStatus.Text = (Get-UiString 'StatusNoResults' 'No results in {0} ms.') -f $swSearch.ElapsedMilliseconds
        $lblTopStats.Text = (Get-UiString 'TopStatsNoResultsFormat' '{0} ({1} ms)') -f (Get-FileCountLabel 0), $swSearch.ElapsedMilliseconds
    } else {
        # When no tokens are entered the result set can be huge (all files).
        # Building the tree collapsed avoids rendering thousands of WPF nodes at once,
        # which would block the UI thread for several seconds.
        $hasTokens = ($tokens -and $tokens.Length -gt 0)
        $autoExpand = $hasTokens -and ($count -le 500)
        $rootNode = [FileNodeV2]::BuildTree($folder, $results, $autoExpand)
        $script:RootTreeNode = $rootNode

        $list = [System.Collections.Generic.List[FileNodeV2]]::new()
        $list.Add($rootNode)
        $treeResults.ItemsSource = $list
        $swTotal.Stop()

        $lblResultBadge.Text = Get-FileCountLabel $count
        # Top badge: search-only time (fast C# scan)
        $lblTopStats.Text = (Get-UiString 'TopStatsFoundFormat' 'Found: {0} ({1} ms)') -f $count, $swSearch.ElapsedMilliseconds
        # Bottom status bar: total time from search start to GUI ready
        $lblStatus.Text = ((Get-UiString 'StatusResultsFound' 'Found {0} files in {1} ms in directory {2}') -f $count, $swSearch.ElapsedMilliseconds, $folder) +
                          ("  |  Total: {0} ms" -f $swTotal.ElapsedMilliseconds)
    }

    [System.Windows.Input.Mouse]::OverrideCursor = $null

    # Save the last search query, date filter, whole word, and same line preference
    Save-AppConfig -SearchFolder $folder -FilterModifiedSince $dpModifiedSince.SelectedDate -FileExtensions $exts -LastSearchQuery $txtSearch.Text -MatchWholeWord $isWhole -MatchSameLine $isSameLine
}

# ── 9. UI events and interactions ────────────────────────────────────────────

# Debounce timer for the search box (configurable delay before starting to search when typing)
$script:DebounceMs = if ($script:Config.SearchDebounceMs -and $script:Config.SearchDebounceMs -gt 0) { [int]$script:Config.SearchDebounceMs } else { 750 }
$script:SearchDebounceTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:SearchDebounceTimer.Interval = [TimeSpan]::FromMilliseconds($script:DebounceMs)
$script:SearchDebounceTimer.Add_Tick({
    $script:SearchDebounceTimer.Stop()
    Invoke-ScriptSearch
})

$script:SuppressDebounceSearch = $false

# Search on click or Enter
$btnSearch.Add_Click({
    $script:SearchDebounceTimer.Stop()
    Invoke-ScriptSearch
})
$txtSearch.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        $script:SearchDebounceTimer.Stop()
        Invoke-ScriptSearch
    }
})

# Dynamic token label update and automatic debounced search with typing delay
$txtSearch.Add_TextChanged({
    Update-TokenLabels
    if ($script:IsWindowLoaded -and -not $script:SuppressDebounceSearch) {
        $script:SearchDebounceTimer.Stop()
        $script:SearchDebounceTimer.Start()
        $lblStatus.Text = Get-UiString 'StatusTypingDelay' 'Typing... search will start shortly (or press Enter)'
    }
})

# Clear query button
$btnClearSearch.Add_Click({
    $script:SearchDebounceTimer.Stop()
    $script:SuppressDebounceSearch = $true
    $txtSearch.Text = ""
    $script:SuppressDebounceSearch = $false
    Invoke-ScriptSearch
    $null = $txtSearch.Focus()
})

# Reset filters
$btnReset.Add_Click({
    $script:SearchDebounceTimer.Stop()
    $script:SuppressDebounceSearch = $true
    $txtSearch.Text = ""
    $script:SuppressDebounceSearch = $false
    if ($chkWholeWord) { $chkWholeWord.IsChecked = $false }
    if ($chkSameLine) { $chkSameLine.IsChecked = $false }
    $dpModifiedSince.SelectedDate = $null
    if ($btnClearDate) { $btnClearDate.Visibility = [System.Windows.Visibility]::Collapsed }
    $txtExtensions.Text = '*.ps1, *.md'
    Update-ExtAllButtonState
    Invoke-ScriptSearch
})

# Whole word & Same line checkbox toggle events
if ($chkWholeWord) {
    $chkWholeWord.Add_Click({
        if ($script:IsWindowLoaded) {
            $script:SearchDebounceTimer.Stop()
            $script:SearchDebounceTimer.Start()
        }
    })
}
if ($chkSameLine) {
    $chkSameLine.Add_Click({
        if ($script:IsWindowLoaded) {
            $script:SearchDebounceTimer.Stop()
            $script:SearchDebounceTimer.Start()
        }
    })
}

# Dynamic date filter events
$dpModifiedSince.Add_SelectedDateChanged({
    if ($btnClearDate) {
        $btnClearDate.Visibility = if ($dpModifiedSince.SelectedDate) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
    }
    if ($script:IsWindowLoaded) {
        $script:SearchDebounceTimer.Stop()
        $script:SearchDebounceTimer.Start()
    }
})

$btnClearDate.Add_Click({
    $script:SearchDebounceTimer.Stop()
    $dpModifiedSince.SelectedDate = $null
    if ($btnClearDate) { $btnClearDate.Visibility = [System.Windows.Visibility]::Collapsed }
    Invoke-ScriptSearch
})

$btnDatePresets.Add_Click({
    $cm = [System.Windows.Controls.ContextMenu]::new()
    $cm.Resources = $window.Resources
    $cm.PlacementTarget = $btnDatePresets
    $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom

    $onDatePresetClick = {
        param($sender, $e)
        $script:SearchDebounceTimer.Stop()
        $tag = $sender.Tag
        if ($null -eq $tag -or $tag -eq 'All') {
            $dpModifiedSince.SelectedDate = $null
        } elseif ($tag -eq 'Today') {
            $dpModifiedSince.SelectedDate = [DateTime]::Today
        } elseif ($tag -eq '24h') {
            $dpModifiedSince.SelectedDate = [DateTime]::Now.AddHours(-24)
        } elseif ($tag -eq 'ThisYear') {
            $dpModifiedSince.SelectedDate = [DateTime]::new([DateTime]::Today.Year, 1, 1)
        } else {
            $days = [int]$tag
            $dpModifiedSince.SelectedDate = [DateTime]::Today.AddDays(-$days)
        }
        if ($btnClearDate) {
            $btnClearDate.Visibility = if ($dpModifiedSince.SelectedDate) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
        }
        Invoke-ScriptSearch
    }

    $addDateMenuItem = {
        param([string]$header, [string]$tagValue)
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $header
        $mi.Tag = $tagValue
        $mi.Add_Click($onDatePresetClick)
        $cm.Items.Add($mi) | Out-Null
    }

    $addDateSeparator = {
        $sep = [System.Windows.Controls.Separator]::new()
        $cm.Items.Add($sep) | Out-Null
    }

    & $addDateMenuItem (Get-UiString 'DatePresetAll' '📅 All Dates (Default)') 'All'
    & $addDateSeparator
    & $addDateMenuItem (Get-UiString 'DatePresetToday' '🕒 Today') 'Today'
    & $addDateMenuItem (Get-UiString 'DatePreset24h' '⏱️ Last 24 Hours') '24h'
    & $addDateMenuItem (Get-UiString 'DatePreset3Days' '📆 Last 3 Days') '3'
    & $addDateMenuItem (Get-UiString 'DatePreset5Days' '📆 Last 5 Days') '5'
    & $addDateMenuItem (Get-UiString 'DatePreset7Days' '📆 Last 7 Days (1 Week)') '7'
    & $addDateMenuItem (Get-UiString 'DatePreset14Days' '🗓️ Last 14 Days (2 Weeks)') '14'
    & $addDateMenuItem (Get-UiString 'DatePreset30Days' '🗓️ Last 30 Days (1 Month)') '30'
    & $addDateMenuItem (Get-UiString 'DatePreset90Days' '🗓️ Last 90 Days (3 Months)') '90'
    & $addDateMenuItem (Get-UiString 'DatePresetThisYear' '🗓️ This Year (Since Jan 1)') 'ThisYear'
    & $addDateSeparator
    & $addDateMenuItem (Get-UiString 'DatePresetClear' '↺ Clear / Show All') 'All'

    $btnDatePresets.ContextMenu = $cm
    $cm.IsOpen = $true
})

# Dynamic extension controls events
$txtExtensions.Add_TextChanged({
    Update-ExtAllButtonState
    if ($script:SearchDebounceTimer) {
        $script:SearchDebounceTimer.Stop()
        $script:SearchDebounceTimer.Start()
    }
})

$txtExtensions.Add_KeyDown({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Return) {
        $script:SearchDebounceTimer.Stop()
        Invoke-ScriptSearch
        $e.Handled = $true
    }
})

$btnExtPresets.Add_Click({
    $cm = [System.Windows.Controls.ContextMenu]::new()
    $cm.Resources = $window.Resources
    $cm.PlacementTarget = $btnExtPresets
    $cm.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom

    $onPresetClick = {
        param($sender, $e)
        $script:SearchDebounceTimer.Stop()
        $tag = $sender.Tag
        if ($tag) {
            if ($tag.Mode -eq 'Set') {
                $txtExtensions.Text = $tag.Value
            } elseif ($tag.Mode -eq 'Append') {
                $targetExt = $tag.Value
                $current = Get-ConfiguredExtensions
                if ($current.Count -eq 1 -and $current[0] -eq '*.*') {
                    $txtExtensions.Text = $targetExt
                } elseif ($current -notcontains $targetExt) {
                    $newExts = @($current) + $targetExt
                    $txtExtensions.Text = ($newExts -join ', ')
                }
            } elseif ($tag.Mode -eq 'Reset') {
                $txtExtensions.Text = '*.ps1, *.md'
            }
        }
        Update-ExtAllButtonState
        Invoke-ScriptSearch
    }

    $addMenuItem = {
        param([string]$header, [string]$mode, [string]$value)
        $mi = [System.Windows.Controls.MenuItem]::new()
        $mi.Header = $header
        $mi.Tag = [PSCustomObject]@{ Mode = $mode; Value = $value }
        $mi.Add_Click($onPresetClick)
        $cm.Items.Add($mi) | Out-Null
    }

    $addSeparator = {
        $sep = [System.Windows.Controls.Separator]::new()
        $cm.Items.Add($sep) | Out-Null
    }

    # Preset packs
    & $addMenuItem (Get-UiString 'PresetScriptsDocs' '⚡📝 Scripts & Docs (*.ps1, *.md) [Default]') 'Set' '*.ps1, *.md'
    & $addMenuItem (Get-UiString 'PresetPowerShell' '⚡ PowerShell (*.ps1, *.psm1, *.psd1)') 'Set' '*.ps1, *.psm1, *.psd1'
    & $addMenuItem (Get-UiString 'PresetMarkdown' '📝 Markdown & Docs (*.md, *.txt)') 'Set' '*.md, *.txt'
    & $addMenuItem (Get-UiString 'PresetSql' '🗄️ SQL Scripts (*.sql)') 'Set' '*.sql'
    & $addMenuItem (Get-UiString 'PresetDataConfig' '📦 Data & Config (*.json, *.xml, *.yaml, *.csv)') 'Set' '*.json, *.xml, *.yaml, *.csv'
    & $addMenuItem (Get-UiString 'PresetCode' '💻 All Code (*.ps1, *.sql, *.cs, *.py, *.js)') 'Set' '*.ps1, *.sql, *.cs, *.py, *.js'
    & $addMenuItem (Get-UiString 'PresetAllFiles' '🌐 All Files (*.*)') 'Set' '*.*'

    & $addSeparator

    # Append actions
    & $addMenuItem (Get-UiString 'PresetAppendSql' '➕ Append *.sql') 'Append' '*.sql'
    & $addMenuItem (Get-UiString 'PresetAppendJson' '➕ Append *.json') 'Append' '*.json'
    & $addMenuItem (Get-UiString 'PresetAppendXml' '➕ Append *.xml') 'Append' '*.xml'
    & $addMenuItem (Get-UiString 'PresetAppendTxt' '➕ Append *.txt') 'Append' '*.txt'

    & $addSeparator

    # Reset
    & $addMenuItem (Get-UiString 'PresetResetDefault' '↺ Reset to Default (*.ps1, *.md)') 'Reset' ''

    $btnExtPresets.ContextMenu = $cm
    $cm.IsOpen = $true
})

$btnExtAll.Add_Click({
    $script:SearchDebounceTimer.Stop()
    $current = Get-ConfiguredExtensions
    if ($current.Count -eq 1 -and $current[0] -eq '*.*') {
        if ($script:PreviousExtensions -and $script:PreviousExtensions.Count -gt 0 -and $script:PreviousExtensions[0] -ne '*.*') {
            $txtExtensions.Text = ($script:PreviousExtensions -join ', ')
        } else {
            $txtExtensions.Text = '*.ps1, *.md'
        }
    } else {
        $script:PreviousExtensions = $current
        $txtExtensions.Text = '*.*'
    }
    Update-ExtAllButtonState
    Invoke-ScriptSearch
})

# Folder selection
$btnBrowse.Add_Click({
    $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = Get-UiString 'BrowseDialogDescription' 'Select the directory with scripts to search'
    $dialog.SelectedPath = $txtFolder.Text
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $txtFolder.Text = $dialog.SelectedPath
        $script:CurrentFolder = $dialog.SelectedPath
        Save-AppConfig -SearchFolder $dialog.SelectedPath -FilterModifiedSince $dpModifiedSince.SelectedDate -LastSearchQuery $txtSearch.Text -MatchWholeWord ($chkWholeWord.IsChecked -eq $true) -MatchSameLine ($chkSameLine.IsChecked -eq $true)
        $lblStatusRight.Text = "$($dialog.SelectedPath) | UTF-8 with BOM"
        Invoke-ScriptSearch
    }
})

# Save as default folder
$btnSaveDefault.Add_Click({
    $folder = $txtFolder.Text.Trim()
    if (Test-Path -LiteralPath $folder) {
        Save-AppConfig -SearchFolder $folder -FilterModifiedSince $dpModifiedSince.SelectedDate -LastSearchQuery $txtSearch.Text -MatchWholeWord ($chkWholeWord.IsChecked -eq $true) -MatchSameLine ($chkSameLine.IsChecked -eq $true)
        $lblStatus.Text = (Get-UiString 'StatusSavedDefault' "Saved '{0}' as default directory in config.json") -f $folder
        $lblStatusRight.Text = "$folder | UTF-8 with BOM"
    } else {
        [System.Windows.MessageBox]::Show((Get-UiString 'MsgFolderMissing' 'Directory does not exist: {0}') -f $folder, (Get-UiString 'MsgFolderMissingTitle' 'Error'), "OK", "Error")
    }
})

# Open folder in Explorer
$btnOpenFolder.Add_Click({
    $folder = $txtFolder.Text.Trim()
    if (Test-Path -LiteralPath $folder) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$folder`""
    }
})

# Handle tree item selection (Preview)
$treeResults.Add_SelectedItemChanged({
    param($s, $e)
    $selectedNode = $e.NewValue
    if ($null -ne $selectedNode -and -not $selectedNode.IsFolder) {
        Show-FilePreview $selectedNode.FullPath
    }
})

# Intercept left click on tree: files are selected/previewed, folders toggle expand without stealing file selection
$treeResults.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $source = $e.OriginalSource
    while ($source -and -not ($source -is [System.Windows.Controls.TreeViewItem])) {
        if ($source -is [System.Windows.Media.Visual]) {
            $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
        } else {
            break
        }
    }
    if ($source -is [System.Windows.Controls.TreeViewItem]) {
        $node = $source.Header
        if ($node -and $node.IsFolder) {
            # Clicking anywhere on the folder toggles expansion without stealing selection from the active file
            $isExpander = ($e.OriginalSource -is [System.Windows.Controls.Primitives.ToggleButton] -or
                           ($e.OriginalSource -is [System.Windows.Shapes.Path] -and $e.OriginalSource.Name -eq "ExpandPath"))
            if (-not $isExpander) {
                $node.IsExpanded = -not $node.IsExpanded
                $e.Handled = $true
            }
        } else {
            # File clicked: select it immediately
            $source.IsSelected = $true
        }
    }
})

# Ensure right-click selects the clicked item in the tree before opening context menu
$treeResults.Add_PreviewMouseRightButtonDown({
    param($s, $e)
    $source = $e.OriginalSource
    while ($source -and -not ($source -is [System.Windows.Controls.TreeViewItem])) {
        if ($source -is [System.Windows.Media.Visual]) {
            $source = [System.Windows.Media.VisualTreeHelper]::GetParent($source)
        } else {
            break
        }
    }
    if ($source -is [System.Windows.Controls.TreeViewItem]) {
        $source.IsSelected = $true
        $null = $source.Focus()
    }
})

# Expand / Collapse the whole tree
$btnExpandAll.Add_Click({
    if ($script:RootTreeNode) {
        Set-TreeExpansion $script:RootTreeNode $true
        $treeResults.Items.Refresh()
    }
})

$btnCollapseAll.Add_Click({
    if ($script:RootTreeNode) {
        Set-TreeExpansion $script:RootTreeNode $false
        # Keep the root node expanded
        $script:RootTreeNode.IsExpanded = $true
        $treeResults.Items.Refresh()
    }
})

# Double-click on a tree item opens the file
$treeResults.Add_MouseDoubleClick({
    param($s, $e)
    $node = $treeResults.SelectedItem
    if ($node -and -not $node.IsFolder -and (Test-Path -LiteralPath $node.FullPath)) {
        Start-Process -FilePath $node.FullPath
    }
})

# Match navigation
$btnPrevMatch.Add_Click({ Jump-ToMatch ($script:CurrentMatchIndex - 1) })
$btnNextMatch.Add_Click({ Jump-ToMatch ($script:CurrentMatchIndex + 1) })

# Preview toolbar actions
$btnPreviewOpenFile.Add_Click({
    if ($script:SelectedFilePath -and (Test-Path -LiteralPath $script:SelectedFilePath)) {
        Start-Process -FilePath $script:SelectedFilePath
    }
})

$btnPreviewVSCode.Add_Click({
    if ($script:SelectedFilePath -and (Test-Path -LiteralPath $script:SelectedFilePath)) {
        $codeCmd = Get-Command code -ErrorAction SilentlyContinue
        if ($codeCmd) {
            Start-Process -FilePath "code" -ArgumentList "-g `"$($script:SelectedFilePath)`""
        } else {
            Start-Process -FilePath $script:SelectedFilePath
        }
    }
})

$btnPreviewOpenDir.Add_Click({
    if ($script:SelectedFilePath -and (Test-Path -LiteralPath $script:SelectedFilePath)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$($script:SelectedFilePath)`""
    }
})

$btnPreviewCopyPath.Add_Click({
    if ($script:SelectedFilePath) {
        [System.Windows.Clipboard]::SetText($script:SelectedFilePath)
        $lblStatus.Text = (Get-UiString 'StatusCopiedPath' 'Path copied to clipboard: {0}') -f $script:SelectedFilePath
    }
})

$btnPreviewCopyText.Add_Click({
    if ($txtPreview.Text) {
        [System.Windows.Clipboard]::SetText($txtPreview.Text)
        $lblStatus.Text = Get-UiString 'StatusCopiedContent' 'Entire file content copied to clipboard.'
    }
})

# Tree context menu
$menuOpenFile.Add_Click({
    $node = $treeResults.SelectedItem
    if ($node -and (Test-Path -LiteralPath $node.FullPath)) {
        Start-Process -FilePath $node.FullPath
    }
})

$menuOpenVSCode.Add_Click({
    $node = $treeResults.SelectedItem
    if ($node -and (Test-Path -LiteralPath $node.FullPath)) {
        $codeCmd = Get-Command code -ErrorAction SilentlyContinue
        if ($codeCmd) {
            Start-Process -FilePath "code" -ArgumentList "-g `"$($node.FullPath)`""
        } else {
            Start-Process -FilePath $node.FullPath
        }
    }
})

$menuOpenFolder.Add_Click({
    $node = $treeResults.SelectedItem
    if ($node -and (Test-Path -LiteralPath $node.FullPath)) {
        Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$($node.FullPath)`""
    }
})

$menuCopyFullPath.Add_Click({
    $node = $treeResults.SelectedItem
    if ($node) {
        [System.Windows.Clipboard]::SetText($node.FullPath)
        $lblStatus.Text = (Get-UiString 'StatusCopiedPathGeneric' 'Copied to clipboard: {0}') -f $node.FullPath
    }
})

$menuCopyRelPath.Add_Click({
    $node = $treeResults.SelectedItem
    if ($node) {
        [System.Windows.Clipboard]::SetText($node.Name)
        $lblStatus.Text = (Get-UiString 'StatusCopiedName' 'Name copied to clipboard: {0}') -f $node.Name
    }
})

# Language selector change
$cmbLanguage.Add_SelectionChanged({
    if (-not $script:IsWindowLoaded) { return }
    $selected = $cmbLanguage.SelectedItem
    if ($selected -and $selected.Tag -and $selected.Tag -ne $script:CurrentLanguage) {
        Set-UiLanguage -LanguageCode $selected.Tag
        Save-AppConfig -SearchFolder $txtFolder.Text.Trim() -FilterModifiedSince $dpModifiedSince.SelectedDate -LastSearchQuery $txtSearch.Text -Language $selected.Tag -MatchWholeWord ($chkWholeWord.IsChecked -eq $true) -MatchSameLine ($chkSameLine.IsChecked -eq $true)
    }
})

# Theme toggle button click handler
$btnThemeToggle.Add_Click({
    $newTheme = if ($script:CurrentTheme -eq 'Light') { 'Dark' } else { 'Light' }
    Apply-Theme -Theme $newTheme
    Save-AppConfig -SearchFolder $txtFolder.Text.Trim() -FilterModifiedSince $dpModifiedSince.SelectedDate -LastSearchQuery $txtSearch.Text -Language $script:CurrentLanguage -Theme $newTheme -MatchWholeWord ($chkWholeWord.IsChecked -eq $true) -MatchSameLine ($chkSameLine.IsChecked -eq $true)
})

# Window keyboard shortcuts (F3 / Shift+F3 to navigate matches, Ctrl+F to search)
$window.Add_KeyDown({
    param($s, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::F3) {
        if ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) {
            Jump-ToMatch ($script:CurrentMatchIndex - 1)
        } else {
            Jump-ToMatch ($script:CurrentMatchIndex + 1)
        }
        $e.Handled = $true
    } elseif ($e.Key -eq [System.Windows.Input.Key]::F -and ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
        $null = $txtSearch.Focus()
        $txtSearch.SelectAll()
        $e.Handled = $true
    }
})

# DWM Window Title Bar mode once the window is loaded
$window.Add_SourceInitialized({
    try {
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($window)
        $isDark = if ($script:CurrentTheme -eq 'Light') { 0 } else { 1 }
        [DwmWindowDarkHelper]::SetTitleBarMode($helper.Handle, $isDark)
    } catch {}
})

# Apply the persisted theme and language before the window is shown
Apply-Theme -Theme $script:CurrentTheme
Set-UiLanguage -LanguageCode $script:Config.Language

# Automatic initial search on startup
$window.Add_Loaded({
    $script:IsWindowLoaded = $true
    Update-TokenLabels
    Invoke-ScriptSearch
    $null = $txtSearch.Focus()
})

# Show the WPF window
$window.ShowDialog() | Out-Null
