# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Este repositório ainda não tem versões SemVer publicadas:
a seção `Baseline` descreve o estado de partida deste changelog e `[Unreleased]` recebe cada melhoria no mesmo commit que a faz.
Ao marcar uma versão, `[Unreleased]` vira `[x.y.z] - data`.

## [Unreleased]

### Added
- (nada ainda)

## Baseline - 2026-10-31

### Contém
- Manifestos Kustomize em `base/` (Postgres, dbaccess, license, AppServer core/rest/telnet/worker, webapp, webagent, printer, smartview,
  seeds de RPO/system/systemload, Jobs de UPDDISTR e compilação, Protheus Manager API e web).
- `argocd/application.yaml` (Application) e `argocd/image-updater.yaml` (10 imagens rastreadas; os seeds ficam fora, com digest fixo no Application).
- `scripts/` de bootstrap do cluster k3d, runtime dos nodes (`k3d-nodes`), segredos, patches do AppServer e cliente SIGAACD.
- Tags de imagem: binários pela versão do componente, seeds pela release (`12.1.2510`).
