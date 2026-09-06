# Model domeny

- **Zdarzenie aktywności** — lokalny, surowy zapis wiadomości albo działania Claude Code wraz z sesją, katalogiem roboczym i branchem.
- **Sugestia przypisania** — odwracalna decyzja agenta, że wskazane zdarzenia dotyczą konkretnego zadania Jiry. Nie jest worklogiem.
- **Propozycja dnia** — centralny podział czasu ze wszystkich worktree, zaokrąglony globalnie do 5 minut. Nieudowodniony czas pozostaje jako `Nieprzypisane`.
- **Worklog** — wpis czasu w Jirze. Może powstać dopiero po ręcznym zatwierdzeniu propozycji przez użytkownika.

Rejestr aplikacji jest źródłem prawdy. Hooki wyłącznie dopisują zdarzenia, MCP udostępnia je agentom i przyjmuje sugestie, a zapis do Jiry pozostaje odpowiedzialnością aplikacji.
