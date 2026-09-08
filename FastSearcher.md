# FastSearcher — Architecture & User Guide

<!-- AUTO:metadata -->
- **Script Path:** `D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher\FastSearcher.ps1`
- **Config Path:** `D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher\config.json`
- **Last Synced:** `2026-09-08`
- **Type:** PowerShell WPF GUI Application (.ps1)
<!-- /AUTO -->

## Overview
<!-- AUTO:overview -->
**FastSearcher** to zaawansowane narzędzie okienkowe (WPF) z obsługą trybów **Dark / Light**, stworzone do błyskawicznego przeszukiwania skryptów PowerShell (`.ps1`) oraz dokumentacji Markdown (`.md`) w całym drzewie katalogów (domyślnie `D:\Skrypty`).

Aplikacja wykorzystuje wielowątkowy silnik w języku C# (`Parallel.ForEach`), co pozwala na przeszukanie ponad 9 000 plików w czasie poniżej **200 milisekund**. Zawiera interaktywny widok drzewa folderów z wirtualizacją UI (WPF `VirtualizingStackPanel`), mechanizm podglądu kodu, nawigator trafień wewnątrz pliku, rozbudowane parsowanie fraz (w tym cudzysłowów z pełnym zachowaniem spacji), opcję dopasowywania całych słów oraz dynamiczny filtr daty modyfikacji (DatePicker z szablonami, domyślnie wszystkie pliki).

## Key Features

1. **Wielowątkowy silnik C# (`FastSearchEngineV2`)**:
   - Przeszukuje zawartość plików `.ps1` i `.md` przy użyciu wszystkich dostępnych rdzeni procesora.
   - Płynne działanie GUI, bez blokowania i z natychmiastowym feedbackiem.
   - **Filtrowanie sygnatur cyfrowych**: automatycznie pomija bloki podpisów cyfrowych (`# SIG # Begin signature block`), dzięki czemu tysiące znaków losowego base64 w certyfikatach nie generują fałszywych trafień dla krótkich akronimów (np. `BC`, `AD`, `SQL`).
2. **Inteligentne parsowanie zapytań i bezwzględne dopasowanie "ALL" (AND)**:
   - **Wiele fraz rozdzielonych spacjami**: wpisanie `BC user compare` wyszukuje wyłącznie pliki zawierające **wszystkie** wyszukiwane frazy (`ALL` keywords). Każdy token musi wystąpić w pliku (w czystym kodzie lub nazwie pliku).
   - **Frazy w cudzysłowach z zachowaniem spacji (no-trim)**: wpisanie `BC "AD compare"` traktuje `"AD compare"` jako jedną całość. Białe znaki wewnątrz cudzysłowów (np. `" DR "` lub `"dr "`) **nie są obcinane**, co pozwala na precyzyjne dopasowanie z dokładnymi spacjami.
   - **Dopasowanie całych słów (`Całe słowa` / `chkWholeWord`)**: dedykowany checkbox przy polu wyszukiwania ograniczający dopasowanie do całych słów ograniczonych granicami słów (`\b`). Szukanie `DR` dopasuje `$DR = 1` lub `DR test`, ale pominie podciągi takie jak `poDRill` czy `DR_test`.
   - **Dopasowanie w tej samej linii (`Ta sama linia` / `chkSameLine`)**: dedykowany checkbox wymagający, aby **wszystkie wpisane frazy występowały w dokładnie tej samej linii** w pliku (lub w nazwie pliku). Zapewnia to natychmiastowe odnajdywanie powiązanych instrukcji w kodzie (np. `param folder`) z pominięciem plików, gdzie słowa te występują w odległych miejscach.
   - **Pomiary znaków interpunkcyjnych**: automatycznie oczyszcza przecinki i średniki poza cudzysłowami (np. `BC, user, compare`).
   - Ignoruje wielkość liter (case-insensitive).
3. **Automatyczne wyszukiwanie w locie (Debounce / opóźnienie 750 ms) i skróty**:
   - Wpisywanie tekstu w polu wyszukiwania czeka na przerwę w pisaniu (domyślnie **750 ms**, konfigurowalne w `config.json` przez `SearchDebounceMs`). Na pasku stanu pojawia się informacja o oczekiwaniu na zakończenie pisania, co zapobiega przedwczesnemu przeszukiwaniu tysięcy plików w trakcie pisania wieloczłonowych fraz.
   - Wciśnięcie `Enter` lub kliknięcie `Szukaj` natychmiast uruchamia przeszukiwanie z zerowym opóźnieniem.
   - Skrót `Ctrl+F` natychmiast przenosi kursor do pola wyszukiwania.
   - Skróty `F3` oraz `Shift+F3` przełączają do następnego/poprzedniego trafienia w podglądzie pliku.
4. **Dynamiczne i w pełni konfigurowalne rozszerzenia plików**:
   - Zamiast statycznych checkboxów aplikacja oferuje elastyczne pole `txtExtensions` akceptujące dowolne rozszerzenia (np. `*.ps1, *.md, *.sql`, `.json .xml`, `*.*`) rozdzielane przecinkami, spacjami lub średnikami.
   - **Menu szablonów (`Presets ▾`)**: szybki wybór gotowych pakietów rozszerzeń (PowerShell, Markdown i dokumenty, Skrypty SQL, Dane i konfiguracja, Kod źródłowy, Wszystkie pliki) oraz akcje szybkiego dołączania (`➕ Dołącz *.sql`, `➕ Dołącz *.json`, itp.).
   - **Przełącznik `*.* All`**: jednym kliknięciem przełącza wyszukiwanie na wszystkie pliki (`*.*`) z wyraźnym podświetleniem aktywności.
   - **Deduplikacja i normalizacja C#**: silnik `FastSearchEngineV2` używa `HashSet<string>`, dzięki czemu nakładające się maski (np. `*.*` z `*.ps1`) nigdy nie duplikują plików ani wyników.
   - **Bogaty system ikon**: automatyczne rozpoznawanie typów plików w drzewie i podglądzie (⚡ PowerShell, 📝 Markdown, 🗄️ SQL, 📦 JSON/YAML, 📰 XML/HTML, 📋 TXT/LOG, 📊 CSV, 💻 C#/Python/JS, ⚙️ Batch/Shell).
5. **Dynamiczny filtr daty modyfikacji (DatePicker & Presets)**:
   - Domyślnie przeszukiwane są **wszystkie pliki** bez ograniczeń czasowych (`FilterModifiedSince: null`).
   - Ciemny kontroler DatePicker (`dpModifiedSince`) pozwala na elastyczny wybór dowolnej daty granicznej.
   - **Menu szablonów (`Presets ▾`)**: natychmiastowy wybór okresu (Dzisiaj, Ostatnie 24h, 3 dni, 5 dni, 7 dni, 14 dni, 30 dni, 90 dni, Ten rok, Wszystkie daty).
   - **Dynamiczny przycisk `✕`**: pojawia się po ustawieniu daty i pozwala 1 kliknięciem przywrócić przeszukiwanie wszystkich plików.
6. **Hierarchiczny widok drzewa (TreeView) z wirtualizacją UI**:
   - Po lewej stronie prezentowane jest drzewo folderów zawierających trafienia. Foldery bez trafień są automatycznie pomijane.
   - Węzły zawierają ikony (📁 dla folderów, ⚡ dla `.ps1`, 📝 dla `.md`) oraz czytelne etykiety rozmiaru i daty.
   - **Wirtualizacja WPF** (`VirtualizingStackPanel.IsVirtualizing`, tryb `Recycling`): WPF renderuje tylko węzły widoczne w oknie, co eliminuje blokowanie GUI nawet przy tysiącach wyników.
   - **Inteligentny `autoExpand`**: drzewo jest automatycznie rozwijane tylko wtedy, gdy podano frazy wyszukiwania **i** wyników jest ≤ 500. Przy pustym zapytaniu lub dużej liczbie wyników drzewo startuje zwinięte, co zapobiega renderowaniu tysięcy węzłów naraz.
   - Przyciski `⊞ Rozwiń` oraz `⊟ Zwiń` do szybkiej kontroli widoku drzewa.
7. **Podgląd zawartości (Content Preview) z płynnym przewijaniem**:
   - Kliknięcie pliku w drzewie natychmiast ładuje jego zawartość po prawej stronie.
   - Prawidłowe przewijanie WPF (`ScrollToLine`) z 4 liniami kontekstu powyżej trafienia.
   - Podświetlenie zaznaczenia pozostaje widoczne nawet po utracie fokusu przez pole tekstowe (`IsInactiveSelectionHighlightEnabled`).
   - Pasek metadanych (rozmiar, łączna liczba linii, data modyfikacji, pełna ścieżka).
   - Przycisk szybkiego kopiowania ścieżki i całego kodu do schowka.
8. **Nawigator dopasowań (Match Navigator)**:
   - Gdy plik zawiera wyszukiwane frazy, pojawia się pasek trafień z przyciskami `▲ Poprzednie` i `▼ Następne`.
   - Kliknięcie powoduje bezpośrednie przewinięcie edytora do linii z trafieniem i zaznaczenie szukanej frazy (z uwzględnieniem opcji całych słów).
9. **Akcje i integracja z narzędziami**:
   - Uruchomienie skryptu / otwarcie pliku w programie domyślnym.
   - Bezpośrednie otwarcie w **Visual Studio Code** (`code -g <plik>`).
   - Otwarcie folderu i zaznaczenie pliku w Eksploratorze Windows (`explorer.exe /select`).
10. **Trwałość konfiguracji (`config.json`)**:
    - Automatyczny odczyt i zapis domyślnego katalogu wyszukiwania, preferencji rozszerzeń, filtrów oraz opcji całych słów.
11. **Dwustopniowy pomiar czasu (Dual Stopwatch)**:
    - **`swSearch`** mierzy wyłącznie czas równoległego skanowania C# (`Parallel.ForEach`). Wynik pojawia się w górnym polu statusu: `Found: N (X ms)`.
    - **`swTotal`** mierzy całkowity czas od zakończenia skanowania do momentu przypisania `ItemsSource` drzewu WPF (tj. `BuildTree` + bindowanie WPF). Wynik pojawia się na dolnym pasku stanu: `| Total: X ms`.
    - Różnica między obiema wartościami pozwala precyzyjnie zmierzyć, ile czasu zajmuje samo budowanie i renderowanie drzewa.

---

## Configuration (`config.json`)

Plik konfiguracyjny znajduje się w folderze aplikacji: `D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher\config.json`.

```json
{
  "SearchFolder": "D:\\Skrypty",
  "FileExtensions": [
    "*.ps1",
    "*.md"
  ],
  "FilterModifiedSince": null,
  "FilterModifiedLast5Days": false,
  "DaysModifiedFilter": 5,
  "SearchInSubfolders": true,
  "LastSearchQuery": "",
  "AutoExpandTree": true,
  "FontSize": 13,
  "Theme": "Dark",
  "Language": "pl",
  "MatchWholeWord": false,
  "MatchSameLine": false,
  "SearchDebounceMs": 750
}
```

---

## UI Components & Controls

| Element | Identyfikator XAML | Opis |
| :--- | :--- | :--- |
| **Folder Path** | `txtFolder` | Ścieżka przeszukiwanego katalogu bazowego |
| **Browse Button** | `btnBrowse` | Okno dialogowe wyboru nowego katalogu |
| **Set Default** | `btnSaveDefault` | Zapisuje aktualny katalog jako domyślny w `config.json` |
| **Search Box** | `txtSearch` | Pole wprowadzania zapytania (obsługuje cudzysłowy, spacje, opóźnienie debounce 750ms, skrót: `Ctrl+F`) |
| **Clear Search** | `btnClearSearch` | Czyści pole wyszukiwania i odświeża wyniki (`✕`) |
| **Whole Word** | `chkWholeWord` | Opcja wyszukiwania tylko całych słów (`Całe słowa`, np. `DR` pomija `poDRill`) |
| **Same Line** | `chkSameLine` | Wymusza występowanie wszystkich szukanych fraz w tej samej linii (`Ta sama linia`) |
| **Search Button** | `btnSearch` | Uruchamia wyszukiwanie natychmiast (skrót: `Enter`) |
| **Reset Filters** | `btnReset` | Czyści zapytanie, resetuje datę do wszystkich plików, odznacza całe słowa/tą samą linię i przywraca rozszerzenia domyślne |
| **Modified Since** | `dpModifiedSince` | Dynamiczny DatePicker do wyboru daty granicznej (domyślnie: wszystkie pliki) |
| **Clear Date** | `btnClearDate` | Przycisk czyszczenia daty do stanu domyślnego (`✕`) |
| **Date Presets** | `btnDatePresets` | Menu szablonów dat (Dzisiaj, 24h, 3d, 5d, 7d, 14d, 30d, 90d, Ten rok, Wszystkie) |
| **Extensions Input** | `txtExtensions` | Pole edycji rozszerzeń (np. `*.ps1, *.md, *.sql, *.*`, rozdzielane przecinkami/spacjami) |
| **Presets Menu** | `btnExtPresets` | Menu szablonów rozszerzeń i szybkich akcji dołączania (`Presets ▾`) |
| **All Files Toggle** | `btnExtAll` | Szybki przełącznik wyszukiwania wszystkich plików (`*.* All`) z podświetleniem aktywnego stanu |
| **Results Tree** | `treeResults` | Hierarchiczne drzewo znalezionych plików i folderów (z wirtualizacją WPF) |
| **Expand / Collapse**| `btnExpandAll`, `btnCollapseAll` | Globalne sterowanie rozwinięciem węzłów |
| **Preview Box** | `txtPreview` | Ciemny edytor podglądu z `ScrollToLine` i trwałym zaznaczeniem |
| **Match Nav** | `btnPrevMatch`, `btnNextMatch` | Przechodzenie do poprzedniego/następnego trafienia (skróty: `Shift+F3` / `F3`) |
| **Status Bar** | `lblStatus`, `lblStatusRight` | Liczba trafień, czas skanowania C# oraz całkowity czas GUI (search + BuildTree + WPF binding) |
| **Top Stats Badge** | `lblTopStats` | Skrócony wynik w nagłówku: `Found: N (X ms)` — czas samego skanowania C# |

---

## Technical Data Flow

```
[User Input: Query + WholeWord + Filters]
             │
             ▼ (Debounce 750ms or Enter)
[FastSearchEngineV2::ParseTokens] ──> Tokenizes into e.g. [" DR ", "compare"] (preserves spaces in quotes!)
             │
             ▼  ◄── swSearch.Start()
[FastSearchEngineV2::Search] ───────> EnumerateFiles (Dynamic: *.ps1, *.sql, *.json, *.*, etc.)
                                     Parallel.ForEach across CPU cores
                                     Filters signature blocks (# SIG # Begin signature block)
                                     Condition: ALL tokens must exist in file
                                     If matchWholeWord: checks IsWholeWordMatch boundaries
             │  ◄── swSearch.Stop()  → shown in top badge as "Found: N (X ms)"
             │
             ▼  ◄── swTotal.Start()
[FileNodeV2::BuildTree] ────────────> Constructs nested tree matching directory structure
                                     autoExpand=true only when tokens present AND count ≤ 500
             │
             ▼
[treeResults.ItemsSource] ──────────> WPF TreeView render (VirtualizingStackPanel — only visible nodes)
             │  ◄── swTotal.Stop()  → shown in status bar as "| Total: X ms"
             │
             (User clicks file)
             ▼
[Show-FilePreview] ─────────────────> ReadAllText + [FastSearchEngineV2::FindMatches(..., matchWholeWord)]
                                     Updates metadata badges & loads code preview
                                     Jumps to first match with ScrollToLine & Select
```

---

## Usage Examples

### Uruchomienie aplikacji:
```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher\FastSearcher.ps1"
```
lub w PowerShell 7+:
```powershell
pwsh.exe -NoProfile -STA -ExecutionPolicy Bypass -File "D:\Skrypty\Mnich_Adam_Skrypty\!Helper\FastSearcher\FastSearcher.ps1"
```

### Przykłady zapytań:
1. `BC AD compare` — wyszuka skrypty zawierające **wszystkie trzy** frazy: `BC`, `AD` oraz `compare`.
2. `BC "AD compare"` — wyszuka skrypty zawierające słowo `BC` oraz dokładną frazę `"AD compare"`.
3. `" DR "` — wyszuka pliki zawierające ciąg `DR` otoczony spacjami (spacje wewnątrz cudzysłowu są zachowywane bez obcinania).
4. `DR` z zaznaczoną opcją **Całe słowa** — wyszuka wystąpienia słowa `DR` jako odrębnego wyrazu (np. `$DR = 1` lub `DR test`), pomijając podciągi w słowach takich jak `poDRill` czy `DR_test`.
5. `param folder` z zaznaczoną opcją **Ta sama linia** — wyszuka pliki, w których słowa `param` oraz `folder` występują w tej samej linijce kodu.
6. Puste pole wyszukiwania + wybrany szablon daty (np. `Ostatnie 5 dni` z menu szablonów lub data w DatePicker) — wyświetli wszystkie pliki zmodyfikowane od wskazanej daty (drzewo startuje zwinięte dla dużych zbiorów).
7. `txtExtensions` ustawione na `*.sql` — przeszukuje wyłącznie skrypty SQL z ikoną 🗄️.
8. `txtExtensions` ustawione na `*.*` (lub kliknięty przycisk `*.* All`) — przeszukuje wszystkie pliki w katalogu z pełną deduplikacją i zabezpieczeniem przed plikami binarnymi powyżej 25 MB.

