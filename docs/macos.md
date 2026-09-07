# This Is Logged na macOS

## Architektura

`This Is Logged.app` zawiera jedną natywną binarkę Swift. Ta sama binarka obsługuje menu oraz trzy
tryby uruchamiane w tle przez `launchd`:

```text
ThisIsLogged --agent-status
ThisIsLogged --agent-reminder
ThisIsLogged --agent-sync
```

Żaden tryb nie otwiera Terminala. Interfejs korzysta z AppKit, komunikacja z Jirą z `URLSession`,
a odczyt lokalnych spotkań z EventKit.

## Instalacja i aktualizacja

Otwórz DMG, przeciągnij aplikację do **Applications** i ją uruchom. Pierwszy start otwiera
konfigurator, jeśli brakuje poprawnych ustawień.

Aktualizacja wersji Node importuje `~/.this-is-logged.env` do nowego magazynu, przełącza istniejące
plisty na binarkę Swift i zachowuje `status.json`, logi oraz stary plik ENV jako kopię zapasową.

## Pliki

| Element | Lokalizacja |
|---|---|
| Aplikacja | `/Applications/This Is Logged.app` lub `~/Applications/This Is Logged.app` |
| Ustawienia i tokeny | `~/Library/Application Support/this-is-logged/settings.json` (`0600`) |
| Stan | `~/Library/Application Support/this-is-logged/status.json` |
| Agenty | `~/Library/LaunchAgents/dev.this-is-fine.this-is-logged.*.plist` |
| Logi | `~/Library/Logs/this-is-logged*.log` |

Tokeny są przechowywane w pliku ustawień, dostępnym wyłącznie dla konta użytkownika. Dzięki temu
aktualizacje lokalnych buildów nie wywołują systemowych monitów o dostęp.

## Zadania `launchd`

### Status

`dev.this-is-fine.this-is-logged.status` startuje przy instalacji, a później co 60 sekund. Sprawdza
dzisiaj, wczoraj, zakończone dni tygodnia i miesiąca oraz miesięczny plan. W poniedziałek zakres
tygodniowy obejmuje poprzedni tydzień pracy.

Przy utracie VPN zachowuje ostatni poprawny raport i zapisuje osobno czas nieudanej próby.

### Przypomnienie

`dev.this-is-fine.this-is-logged.reminder` działa od poniedziałku do piątku o godzinie ustawionej
w aplikacji. Alarmuje zarówno przy 0 h, jak i przy częściowo uzupełnionym dniu. Komunikat wymienia
również wcześniejsze niepełne dni miesiąca.

### Synchronizacja

`dev.this-is-fine.this-is-logged.sync` istnieje wyłącznie przy włączonej drugiej Jirze. Dodaje
brakujące wartości, pomija zgodne i zgłasza różnice do ręcznego rozwiązania.

### Menu

`dev.this-is-fine.this-is-logged.menu` uruchamia aplikację po zalogowaniu użytkownika.

## Synchronizacja interaktywna

Natywne okno pokazuje źródło, cel i decyzję dla każdego dnia. Domyślnie kolizje są pomijane.
Nadpisanie usuwa tylko worklogi zalogowanego użytkownika z wybranego dnia i zawsze wymaga
końcowego potwierdzenia.

Kliknięcie akcji w powiadomieniu o kolizji otwiera to samo okno.

## Kalendarz i analiza czasu

Po włączeniu integracji aplikacja prosi macOS o dostęp, pokazuje lokalne konta kalendarzy i zapisuje
identyfikator wybranego konta. Spotkania ze wszystkich jego kalendarzy są odczytywane tylko w godzinach
pracy, scalane przy nakładaniu i rezerwowane dla zadania zbiorczego przed estymacją aktywności Claude.
Ten sam wynik jest używany w oknie **Analiza czasu…** i przez narzędzie MCP `review_day`.

## Powiadomienia

Jeśli komunikat znika automatycznie:

1. otwórz **Ustawienia systemowe → Powiadomienia → This Is Logged**;
2. włącz powiadomienia;
3. wybierz styl **Stałe**.

macOS nie pozwala aplikacji ustawić stylu bez decyzji użytkownika.

## Logi

| Plik | Zawartość |
|---|---|
| `this-is-logged-status.log` | Odczyty i analiza raportów. |
| `this-is-logged-reminder.log` | Kontrola braków i powiadomienia. |
| `this-is-logged.log` | Opcjonalna synchronizacja. |
| `this-is-logged-menu.log` | Błędy aplikacji AppKit. |

## Diagnostyka

```bash
launchctl print gui/$(id -u)/dev.this-is-fine.this-is-logged.menu
launchctl print gui/$(id -u)/dev.this-is-fine.this-is-logged.status
launchctl print gui/$(id -u)/dev.this-is-fine.this-is-logged.reminder
launchctl print gui/$(id -u)/dev.this-is-fine.this-is-logged.sync
```

Zadania kalendarzowe zwykle mają stan `not running` pomiędzy wykonaniami.

## Typowe problemy

### Menu pokazuje stare dane

Wybierz **Odśwież dane**. Menu czyta cache co 10 sekund, a agent pobiera dane co minutę.

### Jira działa tylko przez VPN

Po rozłączeniu menu pokazuje ostatni poprawny odczyt jako `offline · dane HH:MM`. Po połączeniu
wartości odświeżą się automatycznie.

### Brak drugiej Jiry jest błędem

Wyłącz synchronizację w ustawieniach. Monitoring nie wymaga celu.

### Synchronizacja działa po wyłączeniu

Zapisz ustawienia ponownie. Aplikacja zatrzyma i usunie agent synchronizacji.

### Automatyzacja zgłasza różnicę

Nic nie zostało nadpisane. Otwórz synchronizację interaktywną i wybierz decyzję dla wskazanego dnia.

### Brak służbowego kalendarza na liście

Sprawdź, czy konto służbowe jest widoczne w aplikacji Kalendarz, a następnie włącz dostęp dla
This Is Logged w **Ustawienia systemowe → Prywatność i ochrona → Kalendarze**.
