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
- miesięczny cel powiększany o zapisane nadgodziny, także pracę w dni wolne;
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

Zakładka **Połączenia** zawiera konfigurację obu instancji Jiry. Osobna pozycja **Synchronizacja** w menu bocznym otwiera bezpośrednio przegląd godzin: wybór dowolnego dnia, porównanie źródła i celu, uzupełnianie braków oraz decyzje dotyczące kolizji:

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
odejmowany od pozostałej części dnia i oznaczony w kolumnie **W Jirze**. Dzięki temu aktywność
Claude ani spotkania z Kalendarza nie proponują ponownie godzin, które są już zaraportowane.
Odcinek trwa od wysłania polecenia do następnego polecenia, dzięki czemu obejmuje także czytanie
odpowiedzi, analizę zmian i pisanie kolejnej wiadomości. Po 30 minutach bez kolejnej aktywności jest
automatycznie zamykany.

Bez aktywnego modelu ML w bieżącym dniu brak do czasu, który upłynął od 08:00, jest proporcjonalnie rozdzielany między
rozpoznane zadania. Dashboard jawnie rozdziela czas wynikający ze zdarzeń od dodanej estymacji.
Reguły i ML ograniczają dodatkowe sugestie do pozostałego limitu dnia i czasu, który już upłynął
(od 08:00 lub wcześniejszego pierwszego polecenia). Czas zapisany w Jirze ma pierwszeństwo:
jeśli o 12:43 zaraportowano już 5 godzin, analiza nie dodaje kolejnych godzin z aktywności ani spotkań.
Limit sugestii zaokrąglany jest w dół do 5 minut; zapisane worklogi nie są zmniejszane.
Obok klucza zadania asynchronicznie pobiera jego tytuł z Jiry głównej.

Pełna lista zdarzeń nadal bierze udział w obliczeniu czasu, ale nie jest pokazywana w interfejsie.
Ten moduł działa wyłącznie analitycznie: nie zapisuje worklogów do Jiry.

Hook tylko zapisuje sygnał w tle: nie dodaje instrukcji do rozmowy, nie uruchamia modelu i nie
wywołuje MCP przy każdym poleceniu. Agent korzysta z MCP dopiero na jawną prośbę o analizę lub
przegląd dnia. Aplikacja nie zapisuje odpowiedzi, narzędzi ani surowych payloadów, skraca polecenia
do 1000 znaków. Starsze niż 31 dni zdarzenia pozostają jako lokalne archiwum w tej samej bazie SQLite
(widok `activity_archive`); nic nie jest już usuwane ze względu na wiek. Indeks daty ogranicza odczyt
do wybranego dnia. Archiwum zachowuje przypisania i pozwala ponownie przeliczać historię.
Odczyt MCP zwraca najwyżej 50 wpisów i po 500 znaków tekstu. Wcześniej usunięte dane nie są odtwarzane.

### Lokalne uczenie czasu

`ActivityStore` przechowuje zdarzenia i przypisania, `ActivityEstimator` oblicza propozycję dnia,
a `ActivityLearning` zbiera potwierdzone przykłady i dopasowuje małą regresję Ridge w Swifcie.
Nie wymaga LLM, Pythona, usług chmurowych ani dodatkowych zależności. Tekst poleceń nie jest wejściem
modelu: cechami są minuty sygnałów (odcinki ograniczone do 30 minut) i liczba poleceń dla zadania.

- Uczenie uruchamia się automatycznie przy włączonej integracji Claude, po udanym odświeżeniu statusu,
  najwyżej raz na dobę; po błędzie ponowna próba następuje najwcześniej po godzinie. Urlop je wstrzymuje.
- Odczytuje wyłącznie źródłową Jirę, dla dni sprzed co najmniej dwóch dni. Raporty i cechy muszą
  pozostać takie same przy dwóch odczytach oddzielonych co najmniej 24 godzinami. To ostrożna heurystyka
  stabilności, nie dowód, że użytkownik zakończył raportowanie.
- Brak worklogu dla obserwowanego zadania wyklucza dzień z nauki. Zadanie ogólne i sygnały odrzucone
  przez użytkownika nie są przykładami. Korekta raportów zastępuje poprzedni przykład i wymaga
  ponownego potwierdzenia. Poprawki przypisań lokalnych unieważniają model.
- Dane są oddzielone profilem źródła, danych dostępu, zadania ogólnego, normy dnia i strefy czasowej;
  identyfikator profilu to hash, bez zapisywania tokenu w tabelach uczenia.
- Dopasowanie korzysta z ostatnich 90 dni, ale archiwalne zdarzenia oraz zapisane przykłady nie wygasają.
  Wymaga co najmniej 20 dni i 30 przykładów. Najnowsza ćwiartka dni (minimum 5) służy do walidacji,
  nigdy do dopasowania ocenianego kandydata. Porównanie z dotychczasowym kalkulatorem odbywa się bez
  podawania mu odpowiedzi z Jiry, również bez nich wyliczane są cechy modelu.
- ML jest dopuszczany po zmniejszeniu średniego błędu bezwzględnego o co najmniej 10% i 5 minut
  na zadanie; dopiero wtedy jest ponownie dopasowywany do całego potwierdzonego zbioru.
  Wynik syntetycznych testów nie gwarantuje poprawy na danych użytkownika.
- Model stosuje się tylko do dni późniejszych od jego przykładów i przez najwyżej 14 dni od treningu.
  Dni ze spotkaniami pozostają przy regułach uwzględniających kalendarz. Zapisane godziny nigdy nie są
  zmniejszane ani dodawane ponownie. Wynik ML nie jest sztucznie dopełniany do 8 godzin.
- W nagłówku podziału czasu widać zbieranie danych, aktywny model lub powrót do reguł. Całość pozostaje
  analizą: uczenie i estymacja nie zapisują worklogów ani nie zmieniają synchronizacji i normy dnia.

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
| Synchronizacja | Opcjonalnie kopiuje raporty co 5 minut i po wybudzeniu. |

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
