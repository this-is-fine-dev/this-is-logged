# This Is Logged

> Your worklogs are fine. Probably.

Natywna aplikacja macOS w pasku menu, która pilnuje raportów czasu w Jirze. Pokazuje stan dnia,
tygodnia i miesiąca, przypomina o brakach i opcjonalnie kopiuje dzienne sumy do drugiej Jiry.

Cała aplikacja, klient Jiry i automatyzacja są napisane w Swifcie. Paczka nie wymaga Node.js,
pnpm ani skryptów uruchamianych w Terminalu; do aktualizacji zawiera framework Sparkle.

## Tryby

| Tryb | Jira główna | Jira docelowa | Kontrola raportów | Kopiowanie |
|---|---:|---:|---:|---:|
| Monitoring | wymagana | niepotrzebna | tak | nie |
| Monitoring + synchronizacja | wymagana | wymagana | tak | tak |

Awaria albo wyłączenie synchronizacji nie blokuje odczytu raportów z Jiry głównej.

## Możliwości

- raport dzisiejszy z pełną datą oraz bilans bieżącego miesiąca;
- kontrola wczoraj, tygodnia pracy i zakończonych dni miesiąca;
- wskazanie konkretnych dat i brakujących godzin;
- odświeżanie co minutę przez `launchd`;
- ostatnie poprawne dane widoczne po rozłączeniu VPN;
- trwałe powiadomienia o pustych i niepełnych dniach;
- weekendy i polskie święta ustawowe wyłączone z normy;
- Jira Cloud oraz Jira Server/Data Center;
- opcjonalne porównanie i synchronizacja z drugą Jirą;
- natywne okno rozwiązywania różnic bez Terminala;
- cała konfiguracja dostępna w natywnym oknie aplikacji.
- automatyczne aktualizacje przez Sparkle i GitHub Releases.
- opcjonalne zbieranie aktywności Claude Code ze wszystkich worktree i inteligentna propozycja worklogów.

## Wymagania

- macOS 13.5 lub nowszy;
- token do Jiry głównej;
- token do Jiry docelowej tylko przy synchronizacji;
- bieżąca paczka jest budowana dla Apple Silicon.
- Claude Code jest wymagany tylko po włączeniu integracji aktywności.

## Instalacja

1. Otwórz `This Is Logged.dmg`.
2. Przeciągnij **This Is Logged** do **Applications**.
3. Uruchom aplikację.
4. Podaj dane Jiry głównej, opcjonalnie włącz drugą Jirę i wybierz **Sprawdź i zapisz**.

Konfigurator sprawdza połączenia przed zapisem, zapisuje ustawienia i uzgadnia zadania `launchd`.
Instalacja i konfiguracja nie wymagają Terminala.

Istniejąca konfiguracja `~/.this-is-logged.env` jest automatycznie importowana i pozostaje na
dysku jako kopia zapasowa.

### Tokeny

- **Jira Cloud** (`*.atlassian.net`) — email konta Atlassian oraz API token;
- **Jira Server/Data Center** — Personal Access Token, bez emaila.

## Menu macOS

Nagłówek pokazuje przede wszystkim dzisiejszy raport, a niżej bilans bieżącego miesiąca.

Menu zawiera:

- raport dzisiejszy, wczorajszy, tygodniowy i miesięczny;
- konkretne daty braków i różnic z celem;
- harmonogram przypomnienia;
- ręczne odświeżenie;
- ustawienia i log monitoringu;
- przy aktywnej drugiej Jirze: harmonogram, ręczny zapis, synchronizację interaktywną i historię.

## Powiadomienia

Przypomnienie sprawdza dzisiaj oraz wcześniejsze dni robocze bieżącego miesiąca. Przy normie 8 h
wpis 2 h wywoła komunikat `2.00/8.00 h`, a 8 h lub więcej nie wywoła alarmu.

macOS wymaga zgody użytkownika i może wymagać ręcznego wyboru stylu **Stałe**. System nie pozwala
aplikacji samodzielnie zmienić tej opcji.

## Opcjonalna synchronizacja

Automatyzacja dodaje brakujące dzienne sumy do jednego zadania docelowego. Zgodne dni pomija, a
różnic nigdy nie nadpisuje samodzielnie.

Natywne okno synchronizacji pozwala wybrać dzień, bieżący lub poprzedni miesiąc, a następnie dla
każdej różnicy wybrać:

- **Zsumuj** — dopisz czas źródłowy do istniejącego;
- **Pomiń** — pozostaw cel bez zmian;
- **Nadpisz** — usuń wyłącznie własne wpisy z tego dnia i zapisz wartość źródłową.

Każdy zapis wymaga końcowego potwierdzenia.

## Analiza aktywności Claude Code

Opcję **Zbieraj aktywność z Claude Code** włącza się w ustawieniach aplikacji. Konfigurator sam:

- instaluje hooki Claude Code dla wiadomości użytkownika, odpowiedzi, narzędzi, sesji, subagentów i worktree;
- rejestruje globalny serwer MCP `this-is-logged` dla wszystkich projektów użytkownika;
- pozwala agentom odczytać wspólną aktywność i zapisać sugestię przypisania do zadania Jiry.

Menu **Aktywność Claude Code…** otwiera dzienny podgląd sesji ze wszystkich worktree. Branch lub
treść w formacie `ABC-123` daje automatyczne przypisanie. Podział pokazuje wyłącznie czas wynikający
z zebranych zdarzeń, zaokrąglony globalnie do 5 minut — aplikacja nie dopełnia go sztucznie do 8 h.

Niżej znajduje się pełna oś zdarzeń z timestampami `HH:mm:ss`, rodzajem hooka, kontekstem i
szczegółami. Ten moduł działa wyłącznie analitycznie: nie zawiera przycisku, kodu ani narzędzia MCP
zapisującego worklogi do Jiry.

O ustawionej godzinie przypomnienia aplikacja dołącza informację o gotowej analizie dnia. Przycisk
**Otwórz analizę** w powiadomieniu prowadzi bezpośrednio do dziennego podsumowania.

MCP udostępnia trzy lokalne narzędzia: `get_activity`, `suggest_attribution` i `review_day`. Wszystkie
operują wyłącznie na lokalnym rejestrze aktywności.

## Automatyzacja `launchd`

| Zadanie | Działanie |
|---|---|
| Status | Co minutę odczytuje raporty i zapisuje stan dla menu. |
| Przypomnienie | W dni robocze sprawdza puste i niepełne raporty. |
| Menu | Uruchamia aplikację po zalogowaniu. |
| Synchronizacja | Opcjonalnie kopiuje raporty o ustawionej godzinie. |

Wszystkie zadania uruchamiają tę samą binarkę `ThisIsLogged`. Agent synchronizacji istnieje tylko
po włączeniu drugiej Jiry.

## Dane aplikacji

| Element | Lokalizacja |
|---|---|
| Ustawienia i tokeny | `~/Library/Application Support/this-is-logged/settings.json` (`0600`) |
| Stan i cache offline | `~/Library/Application Support/this-is-logged/status.json` |
| Aktywność Claude Code | `~/Library/Application Support/this-is-logged/activity.sqlite` (`0600`) |
| Agenty | `~/Library/LaunchAgents/dev.this-is-fine.this-is-logged.*.plist` |
| Logi | `~/Library/Logs/this-is-logged*.log` |

## Testy i budowanie

Wymagane są Swift 6 i Command Line Tools for Xcode:

```bash
scripts/test.sh
scripts/package-macos.sh
```

Gotowy obraz trafia do `dist/This Is Logged.dmg`. Bez `MACOS_SIGN_IDENTITY` build jest podpisany
ad hoc i służy do testów lokalnych. Publiczna dystrybucja wymaga Developer ID i notaryzacji.

Po jednorazowej instalacji wersji 2.1 kolejne wydania są sprawdzane automatycznie. Ręczne
sprawdzenie jest dostępne w menu **Aplikacja → Sprawdź aktualizacje…**.

Tag `vX.Y.Z` ustawia wersję aplikacji i uruchamia workflow publikujący podpisane archiwum, DMG i
`appcast.xml` w GitHub Releases. Numer buildu jest nadawany automatycznie. Repozytorium wymaga
sekretu Actions `SPARKLE_PRIVATE_KEY`; jego wartością jest zawartość lokalnego, ignorowanego przez
Git pliku `.sparkle/private-key`.

Notatki z `release-notes/X.Y.Z.md` są osadzane w appcaście i wyświetlane bezpośrednio w oknie
Sparkle. Gdy pliku nie ma, workflow używa tytułów commitów od poprzedniego taga.

## Bezpieczeństwo

- monitoring wykonuje tylko żądania odczytu;
- przy wyłączonej synchronizacji klient docelowej Jiry nie jest tworzony;
- automatyzacja nie nadpisuje różnic;
- operacja nadpisania wymaga ręcznego wyboru i potwierdzenia;
- tokeny nie trafiają do argumentów procesów, plistów, statusu ani logów;
- tokeny są zapisane lokalnie jawnym tekstem w pliku czytelnym tylko dla konta użytkownika.
- wiadomości Claude Code i argumenty narzędzi nie opuszczają lokalnej bazy aplikacji; dostęp do nich ma lokalny MCP włączany przez użytkownika.

Szczegóły systemowe: [Automatyzacja na macOS](docs/macos.md).
