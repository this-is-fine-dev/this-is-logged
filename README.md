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
- cała konfiguracja dostępna w natywnym oknie z boczną nawigacją i uporządkowanymi sekcjami;
- ikona w Docku widoczna podczas pracy w ustawieniach i automatycznie ukrywana po zamknięciu okna;
- automatyczne aktualizacje przez Sparkle i GitHub Releases;
- opcjonalne zbieranie aktywności Claude Code ze wszystkich worktree i inteligentna propozycja worklogów.
- opcjonalne uwzględnianie spotkań z lokalnego Kalendarza macOS.

## Wymagania

- macOS 13.5 lub nowszy;
- token do Jiry głównej;
- token do Jiry docelowej tylko przy synchronizacji;
- bieżąca paczka jest budowana dla Apple Silicon.
- Claude Code jest wymagany tylko po włączeniu integracji aktywności.
- dostęp do Kalendarza jest wymagany tylko po włączeniu spotkań.

## Instalacja

1. Otwórz `This Is Logged.dmg`.
2. Przeciągnij **This Is Logged** do **Applications**.
3. Uruchom aplikację.
4. Podaj dane Jiry głównej, opcjonalnie włącz drugą Jirę i wybierz **Zapisz**.

Konfigurator sprawdza połączenia przed zapisem, zapisuje ustawienia i uzgadnia zadania `launchd`.
Instalacja i konfiguracja nie wymagają Terminala.

Istniejąca konfiguracja `~/.this-is-logged.env` jest automatycznie importowana i pozostaje na
dysku jako kopia zapasowa.

### Tokeny

- **Jira Cloud** (`*.atlassian.net`) — email konta Atlassian oraz API token;
- **Jira Server/Data Center** — Personal Access Token, bez emaila.

## Menu macOS

Nagłówek pokazuje dzisiejszy raport i bilans bieżącego miesiąca. Pasek menu wyświetla zaraportowany
czas, liczbę braków albo znak ukończenia w dzień wolny.

Menu zawiera:

- jedno podsumowanie stanu raportów;
- akcję uzupełnienia raportów, gdy wykryto braki;
- akcję wyjaśnienia synchronizacji, gdy wykryto kolizje;
- analizę dnia, ustawienia i zakończenie aplikacji.

Odświeżanie, bezpieczne uzupełnianie drugiej Jiry i aktualizacje działają automatycznie. Opcje
techniczne pozostają w logach systemowych, a ręczne sprawdzenie aktualizacji jest dostępne w ustawieniach.

## Powiadomienia

Przypomnienie sprawdza dzisiaj oraz wcześniejsze dni robocze bieżącego miesiąca. Przy normie 8 h
wpis 2 h wywoła komunikat `2.00/8.00 h`, a 8 h lub więcej nie wywoła alarmu.

macOS prosi o zgodę dopiero po poprawnym zapisaniu pierwszej konfiguracji. Aplikacja powiadamia o
brakach, kolizjach i awariach; udana synchronizacja pozostaje cicha.

## Opcjonalna synchronizacja

Automatyzacja uzupełnia dzienne sumy w jednym zadaniu docelowym. Gdy Jira docelowa ma mniej czasu
niż główna, dopisuje wyłącznie brakującą różnicę. Zgodne dni pomija, a większej wartości w Jirze
docelowej nigdy nie nadpisuje samodzielnie.

Natywne okno otwierane przy wykryciu różnic pokazuje wyłącznie kolizje wymagające decyzji:

- **Zostaw bez zmian** — nie zmieniaj celu;
- **Dodaj czas ze źródła** — dopisz czas źródłowy do istniejącego;
- **Ustaw jak w głównej Jirze** — usuń wyłącznie własne wpisy z tego dnia i zapisz wartość źródłową.

Każdy zapis wymaga końcowego potwierdzenia.

## Analiza czasu

Opcję **Zbieraj aktywność z Claude Code** włącza się w ustawieniach aplikacji. Konfigurator sam:

- instaluje dwa asynchroniczne hooki: wiadomość użytkownika i koniec odpowiedzi;
- rejestruje globalny serwer MCP `this-is-logged` dla wszystkich projektów użytkownika;
- pozwala agentom odczytać wspólną aktywność i zapisać sugestię przypisania do zadania Jiry.

Ekran **Analiza dnia** w ustawieniach pokazuje proponowany podział czasu ze wszystkich worktree,
Jiry i Kalendarza bez ujawniania surowej listy zdarzeń.
Pozycja w menu tray i akcja z powiadomienia otwierają bezpośrednio ten ekran. Branch lub
treść w formacie `ABC-123` daje automatyczne przypisanie, a kolejne polecenia w tej samej sesji
dziedziczą ostatnie pewne zadanie. Podział jest zaokrąglany globalnie do 5 minut.
Podgląd pobiera też worklogi z głównej Jiry: już zapisany czas jest przypięty do właściwych zadań,
odejmowany od pozostałej części dnia i oznaczony w kolumnie **Podstawa**. Dzięki temu aktywność
Claude ani spotkania z Kalendarza nie proponują ponownie godzin, które są już zaraportowane.
Odcinek trwa od wysłania polecenia do następnego polecenia, dzięki czemu obejmuje także czytanie
odpowiedzi, analizę zmian i pisanie kolejnej wiadomości. Po 30 minutach bez kolejnej aktywności jest
automatycznie zamykany.

W bieżącym dniu brak do czasu, który upłynął od 08:00, jest proporcjonalnie rozdzielany między
rozpoznane zadania. Dashboard jawnie rozdziela czas wynikający ze zdarzeń od dodanej estymacji.
Obok klucza zadania asynchronicznie pobiera jego tytuł z Jiry głównej.

Pełna lista zdarzeń nadal bierze udział w obliczeniu czasu, ale nie jest pokazywana w interfejsie.
Ten moduł działa wyłącznie analitycznie: nie zapisuje worklogów do Jiry.

Hook tylko zapisuje sygnał w tle: nie dodaje instrukcji do rozmowy, nie uruchamia modelu i nie
wywołuje MCP przy każdym poleceniu. Agent korzysta z MCP dopiero na jawną prośbę o analizę lub
przegląd dnia. Aplikacja nie zapisuje odpowiedzi, narzędzi ani surowych payloadów, skraca polecenia
do 1000 znaków i utrzymuje 31-dniową retencję. Odczyt MCP zwraca najwyżej 50 wpisów i po 500 znaków
tekstu.

O ustawionej godzinie przypomnienia aplikacja dołącza informację o gotowej analizie dnia. Przycisk
**Otwórz analizę** w powiadomieniu prowadzi bezpośrednio do dziennego podsumowania.

MCP udostępnia cztery lokalne narzędzia: `get_activity`, `discard_event`, `suggest_attribution` i
`review_day`. Wszystkie operują wyłącznie na lokalnym rejestrze aktywności.

### Spotkania z Kalendarza macOS

W ustawieniach można włączyć spotkania, wybrać konto służbowego kalendarza oraz zadanie zbiorcze, domyślnie
`RPR-18`. macOS prosi wtedy o jednorazowy dostęp do kalendarza. Aplikacja czyta wyłącznie wydarzenia
ze wszystkich kalendarzy wybranego konta i nie modyfikuje ich.

Do podziału czasu trafiają trwające i zakończone wydarzenia w godzinach pracy. Pomijane są wpisy
całodniowe, anulowane, odrzucone, wolne i nieobecności. Nakładające się wydarzenia są scalane,
a ich przedziały mają pierwszeństwo przed estymacją Claude, więc ten sam czas nie jest liczony dwa razy.
Podsumowanie pokazuje nazwy, godziny i długość spotkań; cały ich czas trafia do zadania zbiorczego.

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
sprawdzenie jest dostępne w ustawieniach.

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
