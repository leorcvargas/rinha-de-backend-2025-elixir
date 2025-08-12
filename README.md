# Rinha de Back-end 2025

- **Sobre**
  - Código da minha aplicação em Elixir para a [terceira edição da Rinha de Back-end](https://github.com/zanfranceschi/rinha-de-backend-2025) do [@zanfranceschi](https://github.com/zanfranceschi).
  - Notas
    - A minha intenção inicial era só utilizar ferramentas do ecossistema Elixir/Erlang, mas após experimentar decidi seguir com o HAProxy como load balancer.
    - Como esta é uma aplicação feita para a competição, tem muita coisa aqui que não deve ser feita em ambiente de produção.
  - Tecnologias:
    - HAProxy ou Nginx (load balancer)
    - Elixir (linguagem)
    - ETS (storage engine)
    - Bandit + Plug (HTTP server)
    - libcluster (Inter node connection)
    - Finch (HTTP client)
- **A fazer**
  - [ ] Substituir o ETS pelo Mnesia
  - [ ] Passar a limpo o diagrama rascunho e por aqui
  - [ ] Documentar processo
