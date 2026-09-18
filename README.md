# moleCleaner

Application macOS native (SwiftUI) qui sert d'interface graphique à la CLI
[Mole](https://github.com/tw93/Mole) : surveillance du système, nettoyage,
désinstallation d'apps et maintenance, dans une fenêtre et depuis la barre de menus.

> Projet personnel, sans lien avec « Mole for Mac », l'app officielle de l'auteur de Mole.

## Prérequis

- macOS 14 ou plus récent
- Mole installé : `brew install mole`
- Les Command Line Tools suffisent pour compiler, Xcode n'est pas nécessaire

## Construire

```bash
scripts/build.sh                        # génère build/moleCleaner.app
scripts/build.sh --install              # et la copie dans /Applications
scripts/build.sh --universal            # binaire Apple Silicon + Intel
scripts/make-dmg.sh                     # build/moleCleaner-<version>.dmg (universel)
```

## Distribuer à un autre Mac

`scripts/make-dmg.sh` produit une image disque contenant l'app, un raccourci vers
`Applications` et un LISEZMOI. Le binaire est universel (Apple Silicon et Intel), macOS 14
minimum.

L'app est signée « ad hoc » et **non notariée** : sur un autre Mac, le premier lancement
demande un clic droit → Ouvrir → Ouvrir. Si macOS la déclare « endommagée » (quarantaine
posée par le navigateur ou AirDrop) :

```bash
xattr -dr com.apple.quarantine /Applications/moleCleaner.app
```

Pour un double-clic qui fonctionne du premier coup, il faudrait un compte Apple Developer
(99 $/an) afin de signer avec un Developer ID puis notariser l'app.

Mole n'a pas besoin d'être installé au préalable sur la machine cible : au premier lancement,
l'app détecte son absence et propose de l'installer, avec Homebrew s'il est présent, sinon avec
le script officiel du projet (dans `~/.local/bin`, donc sans mot de passe administrateur).
L'installation par script télécharge et exécute un script distant : l'app affiche la commande
exacte et demande confirmation avant de le faire.

L'icône est générée en vectoriel par `scripts/make-icon.swift` à partir de la silhouette
de taupe du projet Mole (`scripts/mole-mark.png`, récupérée sur mole.fit). Quatre traitements
existent : `a` crème et terre (par défaut), `b` verre sur vert, `c` dégradé de l'app,
`d` silhouette pleine page. Pour en changer :

```bash
ICON_VARIANT=d scripts/build.sh
```

Pour comparer les variantes, `build/make-icon preview <dossier>` écrit un aperçu de chacune
en 512 px, plus un rendu 32 px agrandi pour juger la lisibilité en petite taille.

L'app est signée ad hoc. Au premier lancement hors de `build/`, macOS peut demander
une confirmation (clic droit → Ouvrir).

## Fonctionnalités

| Page | Commande Mole | Fonctionnement |
|------|---------------|----------------|
| État du système | `mo status --watch` | Flux JSON continu : santé, CPU, mémoire, disque, réseau, batterie, processus. Également affiché dans la barre de menus. |
| Nettoyage | `mo clean --dry-run` puis `mo clean` | Aperçu par catégorie et par chemin, puis nettoyage complet. Option pour les caches système (mot de passe admin). Clic droit sur un chemin pour le protéger (`~/.config/mole/whitelist`). |
| Projets | `mo purge --dry-run` | Mole détecte les artefacts de build, tu coches, et l'app les met à la Corbeille. |
| Installeurs | détection de `mo installer` | Même principe pour les .dmg, .pkg, etc. |
| Applications | `mo uninstall --list` / `mo uninstall <noms>` | Liste avec icônes et tailles, sélection multiple, désinstallation par Mole (Corbeille). |
| Optimisation | `mo optimize --dry-run` puis `mo optimize` | Aperçu des tâches et du diagnostic, puis exécution avec ou sans droits admin. |
| Historique | `mo history --json` | Sessions passées et accès aux journaux de Mole. |
| Installation de Mole | `brew install mole` ou le script officiel | Écran d'accueil quand la CLI est absente : installation en un clic, journal en direct, puis relance de l'app. |
| Mise à jour | API GitHub, `brew outdated`, `mo update` | Vérification en lecture seule puis installation. Quatre points d'entrée : menu de l'app, Réglages, pastille en bas de la barre latérale, ligne du popover. |

## Architecture

```
Sources/moleCleaner/
├── App.swift              # Scènes : fenêtre, barre de menus, réglages
├── Mole/                  # Intégration de la CLI
│   ├── MoleCLI.swift          # localisation de `mo`, PATH, fichiers de config
│   ├── ProcessRunner.swift    # exécution simple et en flux (ligne par ligne)
│   ├── TerminalSession.swift  # exécution dans un PTY + invites sudo
│   ├── Parsers.swift          # lecture de la sortie texte de Mole
│   └── Models.swift           # JSON de status, history, uninstall
├── Stores/                # État observable par fonctionnalité
└── Views/                 # Interface SwiftUI
```

### Droits administrateur

Les opérations qui peuvent nécessiter sudo sont lancées via
`/usr/bin/script`, qui fournit un pseudo-terminal servant de terminal de contrôle.
Si l'option admin est cochée, l'app lance d'abord `sudo -v`. Mole réutilise ensuite
ce ticket sudo, qui est lié au terminal. Quand une invite de mot de passe apparaît,
l'app affiche une fenêtre native. Le mot de passe est écrit dans le PTY puis oublié :
il n'est ni stocké ni journalisé. Le ticket est révoqué (`sudo -k`) à la fin de la
commande.

### Mise à jour de Mole

La vérification ne modifie rien : version installée par `mo --version`, dernière version publiée
via l'API GitHub, et pour une installation Homebrew `brew outdated --formula mole`, car une
version peut être publiée sur GitHub avant d'arriver dans la formule Homebrew (c'est la règle
que Mole applique lui-même). Elle est faite au lancement, au plus une fois par jour, avec le
résultat en cache ; réglable dans les Réglages.

L'installation délègue à `mo update`, qui choisit son canal : `brew update` puis
`brew upgrade mole` pour une installation Homebrew, sinon une réinstallation par script (qui
peut demander le mot de passe administrateur, géré par la même fenêtre que les autres
opérations). Le binaire étant remplacé pendant l'opération, l'app relit ensuite la version et
relance le collecteur de `mo status`.

### Limites connues

- L'app lit la sortie texte de Mole : une évolution du format de Mole peut demander
  d'adapter `Parsers.swift`.
- La détection des installeurs source `installer.sh` de Mole avec `MOLE_TEST_MODE=1`
  (API interne) pour récupérer les chemins sans lancer son menu interactif.
- Les mises à la Corbeille faites depuis Projets et Installeurs n'apparaissent pas
  dans `mo history`.
- L'analyse visuelle du disque (`mo analyze`) n'est pas encore intégrée.
