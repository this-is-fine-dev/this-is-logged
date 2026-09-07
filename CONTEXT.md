# Model domeny

- **Zdarzenie aktywności** — lokalny, skrócony zapis polecenia użytkownika albo znacznika końca odpowiedzi wraz z sesją, katalogiem roboczym i branchem.
- **Sugestia przypisania** — odwracalna decyzja agenta, że wskazane zdarzenia dotyczą konkretnego zadania Jiry. Nie jest worklogiem.
- **Propozycja dnia** — centralny, wyłącznie analityczny podział czasu ze wszystkich worktree, zaokrąglony globalnie do 5 minut.
- **Szum** — bieżące polecenie odrzucone przez agenta jako rozmowa lub aktywność nieprzydatna do analizy pracy; zachowuje wyłącznie timestamp jako granicę czasu.

Rejestr aplikacji jest źródłem prawdy. Hook zapisuje tylko bieżące polecenie i koniec odpowiedzi. Model ocenia wyłącznie bieżące polecenie: może je odrzucić jako szum albo przypisać do zadania. MCP nie zapisuje worklogów do Jiry.

Czas zadania biegnie od polecenia do następnego polecenia użytkownika, więc obejmuje generowanie odpowiedzi, czytanie, analizę kodu i pisanie kolejnej wiadomości. Pojedynczy odcinek ma limit 30 minut bezczynności.
