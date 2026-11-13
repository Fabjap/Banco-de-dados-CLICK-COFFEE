 Click \& Coffee — Banco de Dados PostgreSQL / Supabase



1. Apresentação



O Click \& Coffee é um projeto acadêmico de comércio eletrônico voltado à comercialização de cafés gourmet, kits e acessórios.



Este repositório disponibiliza os scripts SQL referentes à implementação do banco de dados, desenvolvido em PostgreSQL e hospedado na plataforma Supabase.



2. Objetivo



Demonstrar a estrutura, os relacionamentos, as regras de negócio e os mecanismos de segurança implementados no banco de dados, permitindo sua análise técnica sem necessidade de acesso administrativo ao ambiente de produção.



 3. Tecnologias utilizadas



\- PostgreSQL

\- Supabase

\- SQL

\- Row Level Security (RLS)



4. Inventário técnico consolidado



| Componente-----------------|---Quantidade--|

|----------------------------|---------------|

| Tabelas--------------------|-------21------|

| Colunas -------------------|-------166-----|

| Chaves estrangeiras--------|--------28-----|

| Índices válidos------------|--------63-----|

| Funções--------------------|--------35-----|

| Políticas RLS -------------|--------60-----|

| Tabelas com RLS habilitada-|--------21-----|



Os quantitativos correspondem ao inventário técnico consolidado durante o desenvolvimento.



5. Organização dos arquivos



Pasta `sql`



\- `click\_coffee\_estrutura.sql` — Estrutura principal do banco, incluindo tabelas, relacionamentos, funções, gatilhos e políticas de segurança.

\- `click\_coffee\_auth\_trigger.sql` — Gatilho complementar associado à criação de usuários no Supabase Auth.



 6. Segurança



O banco utiliza políticas de segurança em nível de linha (RLS), restrições de integridade, funções e mecanismos de controle de acesso.



Os scripts são disponibilizados para fins de documentação e avaliação acadêmica, sem exportação dos registros comerciais.



7. Arquitetura prevista



A arquitetura do sistema está organizada conceitualmente em três camadas:



\- \*\*Apresentação:\*\* - interfaces destinadas a clientes e administradores.

\- \*\*Aplicação:\*\* - back-end Python responsável pelos serviços e regras de negócio.

\- \*\*Persistência:\*\* -  PostgreSQL/Supabase, responsável pelos dados e mecanismos de segurança.



A implementação do front-end e do back-end está prevista para etapas futuras.



 8. Limitações



Os scripts representam a estrutura documentada do banco de dados e não constituem uma implantação automaticamente validada em outro ambiente.



Os módulos específicos de fidelidade e recomendações permanecem previstos para evolução futura do sistema.



 9. Finalidade do repositório



Este repositório foi organizado para apresentação acadêmica, documentação técnica e demonstração do desenvolvimento do banco de dados Click \& Coffee.



13/11/2026

