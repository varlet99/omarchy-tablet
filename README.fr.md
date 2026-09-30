# Omarchy Tablet

**Utiliser Omarchy au toucher, puis retrouver le bureau d’un simple bouton.**

Omarchy Tablet adapte l’interface d’Omarchy aux tablettes et aux ordinateurs à clavier détachable. Il ajoute une page d’applications, des favoris, une recherche, un sélecteur de fenêtres, un clavier à l’écran et des raccourcis de dictée. Les thèmes et les widgets natifs d’Omarchy restent intégrés à la barre.

Le projet a été développé sur une **Microsoft Surface Pro 4 équipée du noyau linux-surface**. Il peut servir de base à d’autres tablettes capables de faire fonctionner une version compatible d’Omarchy, sous réserve du support matériel Linux. Ces autres appareils n’ont pas encore été validés.

![Accueil Omarchy Tablet sur Surface Pro 4](preview.png)

## Les trois modes

| Mode | Comportement |
| --- | --- |
| **Tablet** | Active les commandes tactiles et la disposition **Single app** : l’application active est maximisée sur l’écran intégré, avec la navigation accessible. |
| **Desktop** | Rétablit les états de fenêtres modifiés par le plugin et la disposition en mosaïque habituelle d’Omarchy/Hyprland. |
| **Automatic** | Choisit Desktop lorsqu’un clavier physique est détecté et Tablet lorsqu’il est retiré. |

**Hyprland reste actif dans les deux modes.** Single app ne lance pas un autre environnement et ne limite pas le système à une seule application : plusieurs applications restent ouvertes et accessibles dans le sélecteur de fenêtres.

Le bouton situé en haut à gauche permet de passer manuellement de Tablet à Desktop. Ce choix manuel reste en vigueur jusqu’à un nouveau changement. Pour suivre de nouveau le branchement du clavier, choisir **Settings → Mode → Automatic**.

Le mode Desktop conserve le bouton de bascule et la barre supérieure du plugin. Pour retrouver complètement la barre Omarchy d’origine, désactiver le plugin.

## Naviguer au toucher

- Ouvrir l’accueil avec le bouton Applications ou toucher la poignée inférieure.
- Rechercher une application ou choisir un favori. Un appui long permet de modifier les favoris.
- Glisser vers le haut depuis la poignée, maintenir celle-ci ou toucher Windows pour afficher les fenêtres ouvertes.
- Choisir le clavier automatique dans les champs compatibles, ou **Button only** pour l’ouvrir manuellement.
- Choisir l’apparence du clavier : Omarchy, Rounded ou High contrast.
- Utiliser le microphone pour appeler Murmure ou une autre commande de dictée configurée. Le plugin fournit le raccourci; l’application choisie réalise la transcription.

L’interface du plugin est actuellement en anglais. La langue du clavier est indépendante; le clavier canadien-français a servi au développement.

## Installation et retrait

Le [README anglais](README.md#compatibility-and-dependencies) donne les dépendances et les procédures complètes. La base utilisée est Omarchy 4.0.4, Quickshell 0.3.1 et Hyprland 0.56.2. Python 3.11+, PyGObject (`python-gobject`) et `iio-sensor-proxy` sont nécessaires; Squeekboard fournit le clavier et Murmure est optionnel.

Installation des dépendances :

```sh
sudo pacman -S iio-sensor-proxy python-gobject squeekboard
sudo systemctl enable --now iio-sensor-proxy.service
```

Installer depuis le dépôt :

```sh
omarchy plugin add https://github.com/ekiel/omarchy-tablet.git --enable
omarchy plugin update surface.tablet
# Désactiver et revenir à la barre Omarchy :
omarchy plugin disable surface.tablet
# Retirer :
omarchy plugin remove surface.tablet
```

Pour le développement depuis un clone séparé, `python3 install.py` installe une copie versionnée et sauvegarde la sélection de barre; `python3 install.py --restore` la restaure. Ne pas mélanger cet installateur avec une installation gérée par Git. Les favoris sont conservés après le retrait.

## Compatibilité et état du projet

La rotation automatique utilise `iio-sensor-proxy` avec l’accéléromètre pris en charge par le noyau (tel que `intel-ish-hid` sur le noyau d'origine pour Surface Go 2). La prise en charge du tactile, du stylet et de la veille dépend de Linux sur chaque appareil. Les écrans externes conservent leur disposition de fenêtres, mais utilisent eux aussi la barre de remplacement.

La navigation et les mécanismes de restauration ont des tests; les essais physiques au doigt, le détachement/rebranchement réel du clavier et une dictée complète restent à confirmer pour la publication. Les limites précises figurent dans le [bilan de préparation](docs/release-readiness.md). Licence [MIT](LICENSE).
