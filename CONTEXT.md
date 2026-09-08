# Model domeny

- **Zdarzenie aktywności** — lokalny, skrócony zapis polecenia użytkownika albo znacznika końca odpowiedzi wraz z sesją, katalogiem roboczym i branchem.
- **Sugestia przypisania** — odwracalna decyzja zapisana podczas ręcznego przeglądu, że wskazane zdarzenia dotyczą konkretnego zadania Jiry. Nie jest worklogiem.
- **Propozycja dnia** — centralny, wyłącznie analityczny podział czasu ze wszystkich worktree, zaokrąglony globalnie do 5 minut.
- **Czas zapisany** — worklog z głównej Jiry; pewna część propozycji dnia przypisana do konkretnego zadania, której nie wolno estymować ponownie.
- **Szum** — polecenie odrzucone podczas przeglądu jako rozmowa lub aktywność nieprzydatna do analizy pracy; zachowuje wyłącznie timestamp jako granicę czasu.

Rejestr aplikacji jest źródłem prawdy. Asynchroniczny hook zapisuje tylko bieżące polecenie i koniec odpowiedzi, niczego nie dodaje do kontekstu Claude'a i nie uruchamia MCP. Klucz Jiry jest wykrywany lokalnie z brancha lub treści, a kolejne polecenia dziedziczą ostatnie pewne przypisanie w sesji. MCP służy wyłącznie do jawnie wywołanego przeglądu i nie zapisuje worklogów do Jiry.

Czas zadania biegnie od polecenia do następnego polecenia użytkownika, więc obejmuje generowanie odpowiedzi, czytanie, analizę kodu i pisanie kolejnej wiadomości. Pojedynczy odcinek ma limit 30 minut bezczynności. Kalkulator najpierw rezerwuje czas już zapisany w głównej Jirze i spotkania, a tylko pozostałą część dnia rozdziela według aktywności Claude.

W bieżącym dniu roboczym, jeśli istnieje choć jedno rozpoznane zadanie, brak do czasu, który upłynął od 08:00, jest rozdzielany proporcjonalnie między zaobserwowane zadania. Czas zaobserwowany i estymowany pozostają osobno widoczne w interfejsie.
