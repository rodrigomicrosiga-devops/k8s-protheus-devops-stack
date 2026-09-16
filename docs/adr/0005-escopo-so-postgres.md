# ADR 0005 — Cluster Kubernetes roda só Postgres; MSSQL/Oracle ficam exclusivos do Compose

## Status
Aceito (2026-09-16).

## Contexto
O Compose local (`docker-protheus-devops-stack`) suporta 3 bancos via profile (`postgres`,
`mssql`, `oracle`), usado como matriz de compatibilidade. O repo Kubernetes hoje só tem
manifesto de Postgres (`base/postgres.yaml`). `oracle_db` no Compose nem tem imagem publicada —
ainda faz build local a partir de um repo (`docker-protheus-oracle`) conhecidamente quebrado.

## Decisão
O cluster Kubernetes fica deliberadamente com um único caminho de banco (Postgres). MSSQL e
Oracle continuam existindo apenas no Compose local, como ambiente de validação de
compatibilidade multi-SGBD do AppServer — não como algo a portar para o cluster no momento.

## Consequências
- Menos superfície para fechar as Fases C/D/E do AppServer no k3d.
- Se o cluster precisar de MSSQL no futuro, o caminho natural é um `overlays/` do Kustomize
  (hoje o repo só tem `base/`, sem overlays) — não duplicar `base/postgres.yaml` in-place.
- Reabrir esta decisão exige razão explícita nova, não assumir que ficou esquecida.
