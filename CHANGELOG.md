# Changelog

Formato [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Este repositório ainda não tem versões SemVer publicadas:
a seção `Baseline` descreve o estado de partida deste changelog e `[Unreleased]` recebe cada melhoria no mesmo commit que a faz.
Ao marcar uma versão, `[Unreleased]` vira `[x.y.z] - data`.

## [Unreleased]

### Added
- `scripts/secrets/export-live-secrets.sh` (+ teste): exporta para o cofre GPG os Secrets `smartview-secret` e `appserver-upddistr-secret`, que só existiam no cluster. Confere por padrão (sem ler valores); `--run` exige TTY, prova a passphrase do cofre antes de ler e confere o arquivo novo por hash. `.gitignore` cobre o texto puro correspondente.
- `scripts/secrets/seal-topology.sh` (+ teste): sela `postgres-secret` e `smartview-secret` (e, com `--with-upddistr`, o `appserver-upddistr-secret`) a partir do cofre GPG para o namespace de uma topologia nova e grava os `SealedSecret` no catálogo privado (`topologies/<namespace>/`). Escopo `strict`; confere por padrão (sem ler valores); `--run` exige TTY, prova a passphrase antes de ler, confere as chaves contra `topology/*.sealed.yaml`, recusa o namespace da produção e não sobrescreve. Nada é aplicado no cluster.

### Changed
- Manifestos separados em `topology/` (48 objetos: tudo o que pertence a uma topologia Protheus), `cluster/` (15 objetos que existem uma vez só: Protheus Manager API/web e `regcred`) e `base/`, que passa a ser só a raiz que compõe as duas. A `Application` continua com `path: base`; o `kubectl kustomize base` ficou **byte a byte idêntico** (63 objetos).
- `scripts/appserver-patch/run-job.sh` lê os Jobs de `topology/`.

## Baseline - 2026-10-31

### Contém
- Manifestos Kustomize em `base/` (Postgres, dbaccess, license, AppServer core/rest/telnet/worker, webapp, webagent, printer, smartview,
  seeds de RPO/system/systemload, Jobs de UPDDISTR e compilação, Protheus Manager API e web).
- `argocd/application.yaml` (Application) e `argocd/image-updater.yaml` (10 imagens rastreadas; os seeds ficam fora, com digest fixo no Application).
- `scripts/` de bootstrap do cluster k3d, runtime dos nodes (`k3d-nodes`), segredos, patches do AppServer e cliente SIGAACD.
- Tags de imagem: binários pela versão do componente, seeds pela release (`12.1.2510`).
