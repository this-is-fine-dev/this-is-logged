# Claude Code + This Is Logged: redukcja opóźnień MCP

Data analizy: 2026-09-08

## Wniosek

Największe opóźnienie nie powstaje w samym MCP ani SQLite. Obecny synchroniczny hook
`UserPromptSubmit` dodaje do kontekstu polecenie, aby Claude przy każdej wiadomości zdecydował o
atrybucji i wywołał `suggest_attribution`. To dokłada rozumowanie, wyszukanie narzędzia i zwykle
co najmniej jedną dodatkową rundę model–narzędzie do zwykłej odpowiedzi.

Docelowy podział odpowiedzialności:

1. **Hot path:** asynchroniczny i niemy zapis sygnału; bez LLM, stdout i wywołania MCP.
2. **Warm path:** lokalne reguły przypisania oraz scalanie sąsiednich sygnałów w segmenty.
3. **Cold path:** jedno zbiorcze rozpoznanie wyłącznie niejednoznacznych segmentów po bezczynności
   lub podczas dziennego przeglądu.

MCP powinno pozostać małym interfejsem do odczytu i korekty danych. Nie powinno sterować główną
pętlą Claude przy każdym promptcie.

## Co dokładnie spowalnia obecną implementację

- Hook `UserPromptSubmit` jest jedynym skonfigurowanym jako synchroniczny.
- Po zapisie zwraca `additionalContext`, które każe Claude klasyfikować bieżącą wiadomość i używać
  `suggest_attribution`.
- Sam zapis otwiera SQLite, sprawdza schemat i migrację, wykonuje retencję, ustawia prawa plików oraz
  uruchamia osobny proces `git branch --show-current`.
- MCP zwraca tę samą strukturę jako sformatowany tekst i `structuredContent`, co powiększa wynik.

Pierwsze trzy operacje systemowe warto mierzyć i upraszczać dopiero po usunięciu LLM z hot path.
Największy zysk da jedna zmiana: async + brak stdout.

## Rekomendowana architektura

### 1. Natychmiastowy P0

- Ustawić `UserPromptSubmit` na `async: true`.
- Nie zwracać `additionalContext`, tekstu ani `systemMessage`.
- Zapisywać tylko: czas, `session_id`, `cwd`, identyfikator promptu, krótki tekst tymczasowy i jawny
  klucz Jiry, jeśli da się go znaleźć bez modelu.
- Kolejność deterministycznej atrybucji: klucz z brancha, klucz w promptcie, ostatnie pewne
  przypisanie sesji/worktree, brak przypisania.

Claude Code dokumentuje, że hooki domyślnie blokują wykonanie, a `async: true` pozwala kontynuować
natychmiast. Jednocześnie wynik asynchronicznego hooka trafia do modelu w następnym turnie, dlatego
hook rejestrujący powinien nic nie wypisywać.

### 2. Segmenty zamiast surowych wiadomości

Scalić sąsiednie zdarzenia o tym samym `(session, worktree, issue)` w jeden segment czasu. To jest
wzorzec heartbeat znany z ActivityWatch: identyczne, pobliskie sygnały są łączone, co ogranicza IO i
liczbę rekordów. Surowe prompty mogą mieć krótki TTL, a trwałe mają być segmenty, poprawki
użytkownika i zaakceptowane raporty.

### 3. Dokładniejszy zegar z natywnego OpenTelemetry

Claude Code publikuje `claude_code.active_time.total`. Metryka uwzględnia pisanie, czytanie
odpowiedzi oraz pracę CLI, a pomija idle. Claude potrafi wysyłać metryki i zdarzenia do lokalnego
endpointu OTLP przez `http/json`, z eksportem wykonywanym partiami. To lepsze źródło czasu niż samo
zgadywanie z odstępów między promptami.

Proponowany układ docelowy:

- OTel mierzy czas aktywny per `session.id`;
- jeden lekki sygnał mapuje sesję na worktree/branch;
- centralny moduł scala nakładające się sesje do unii czasu, aby praca agentów równolegle nie
  podwajała ludzkiego czasu;
- kalendarz rezerwuje spotkania;
- klasyfikator rozdziela tylko nierozstrzygnięte segmenty.

Wdrożenie odbiornika OTLP jest większe niż P0, więc należy je poprzedzić małym prototypem. Format
transkryptów Claude jest oficjalnie oznaczony jako wewnętrzny i zmienny; OTel jest stabilniejszym
źródłem telemetrii.

### 4. Jedna analiza zbiorcza

Model powinien otrzymać tylko deltę od ostatniego kursora, np. listę segmentów:

```text
08:03–08:47 | worktree A | branch RPR-1462 | 7 promptów | Edit/Write/Test
08:47–09:12 | worktree B | branch bez klucza | 3 prompty | nierozstrzygnięte
```

Do modelu wysyłamy wyłącznie segmenty bez pewnej atrybucji. Wynik zapisujemy jednym batchem.
Poprawka użytkownika staje się trwałą regułą `worktree/branch/session -> issue`, więc podobna decyzja
nie wymaga kolejnego LLM.

Jeśli analiza ma działać całkiem samoczynnie w tle, aplikacja potrzebuje własnego wywołania modelu
(np. API). Sam MCP nie uruchamia modelu; tylko udostępnia narzędzia modelowi, który już prowadzi
rozmowę. Bez osobnego wywołania rozsądny wariant to analiza przy otwarciu dziennego podsumowania.

## Inspiracje z istniejących projektów

- **Claude Code Timelog:** wykrywa ticket najpierw z brancha, potem z promptu; liczy czas z przerw
  między zdarzeniami, obejmując czas przetwarzania i czytania. Nie używa LLM w hot path.
- **claude-task-tracker:** ma stały worker, zapamiętuje offset bajtowy transkryptu, czyta tylko deltę,
  pomija analizę poniżej `minDeltaChars` i ogranicza analizę do jednego turnu.
- **ActivityWatch:** scala sąsiednie heartbeat-y w oknie `pulsetime`.
- **WakaTime:** rate-limit heartbeats oraz kolejka offline; zgłoszenia błędów pokazują, że ponowne
  parsowanie całych transkryptów może powodować wysokie CPU.
- **LangGraph / Letta:** konsolidują pamięć w tle, ponieważ decydowanie o zapisie pamięci w hot path
  zwiększa opóźnienie i rozprasza główny model.
- **OpenTelemetry:** używa ograniczonej kolejki i okresowego eksportu partii; emiter nie powinien
  blokować aplikacji.

Nie ma potrzeby dodawania vector DB, grafu wiedzy ani frameworka pamięci. Wystarczą istniejące SQLite,
segmenty, kursor przetwarzania i kilka trwałych reguł atrybucji.

## Kolejność wdrożenia i kryteria

1. P0: async silent hook; cel: 0 wymuszonych wywołań MCP w zwykłym turnie.
2. Dodać pomiar czasu hooka i czasu do pierwszego tokenu; cel hooka: p95 poniżej 50 ms.
3. Segmenty, sticky attribution i dzienny batch tylko dla niejednoznacznych okresów.
4. Prototyp lokalnego odbiornika OTel; wdrażać tylko, jeśli poprawia zgodność z rzeczywistym czasem.
5. Dopiero gdy proces hooka nadal przekracza budżet: cache brancha, retencja raz dziennie i stałe
   połączenie/zapis paczkami do SQLite.

## Źródła

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
- [Claude Code MCP and Tool Search](https://code.claude.com/docs/en/mcp)
- [Claude Code monitoring and OpenTelemetry](https://code.claude.com/docs/en/monitoring-usage)
- [ActivityWatch heartbeats](https://docs.activitywatch.net/en/latest/buckets-and-events.html)
- [Claude Code Timelog](https://github.com/RemoteCTO/claude-code-timelog)
- [claude-task-tracker](https://github.com/ProblemFactory/claude-task-tracker)
- [claude-worktime](https://github.com/Gunther-Schulz/claude-worktime)
- [WakaTime CLI](https://github.com/wakatime/wakatime-cli)
- [LangChain memory: hot path vs background](https://docs.langchain.com/oss/python/concepts/memory)
- [Letta memory and dreaming](https://github.com/letta-ai/letta-docs-md/blob/main/configuration/memory/index.md)
- [OpenTelemetry Logs SDK batching processor](https://opentelemetry.io/docs/specs/otel/logs/sdk/)
