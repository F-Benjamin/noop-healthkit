# WHOOP 5.0 → Apple Santé

**Projet iOS personnel · Swift · CoreBluetooth · SQLite · HealthKit**

Ce fork de [NOOP](https://github.com/ryanbr/noop) transforme les mesures d’un bracelet WHOOP 5.0 en données utilisables dans Apple Santé. L’analyse dans Bevel s’appuie sur Santé. Le défi principal était de conserver la précision des données du bracelet pour les calculs locaux tout en maîtrisant le volume écrit dans HealthKit.

## Ma contribution

| Problème | Solution mise en place |
| --- | --- |
| Le bracelet fournit une mesure cardiaque par seconde environ. | Séparation du stockage brut et de la file d’export. En arrière-plan, NOOP sélectionne au maximum une vraie mesure par minute, sans interpolation. |
| Une synchronisation volumineuse peut bloquer l’interface. | Traitement séquentiel par métrique, par lots bornés, avec état de progression et reprise après interruption. |
| Une relance ou une correction peut créer des doublons. | Identifiants stables, versions HealthKit et registre local qui associe chaque mesure à son UUID dans Santé. |
| Le brut haute fréquence grossit vite. | Fenêtre de rétention locale de 24 h, puis purge incrémentale des données devenues inutiles. Les écritures non terminées restent protégées. |
| Une anomalie d’export peut surcharger Santé. | Limites de débit, suivi de la file réellement exportable et coupe-circuit qui suspend l’export tout en laissant la collecte locale continuer. |

## Parcours des données

```mermaid
flowchart LR
    A["WHOOP 5.0"] -->|Bluetooth LE| B["Stockage local SQLite"]
    B --> C["Normalisation et calculs"]
    C --> D["Projection par métrique et contexte"]
    D --> E["File d’export bornée"]
    E --> F["Apple Santé via HealthKit"]
    F --> G["Bevel"]
```

Le flux initial couvre la fréquence cardiaque et la variabilité cardiaque SDNN calculée à partir des intervalles R–R. L’intégration a ensuite été étendue aux stades de sommeil, à la fréquence respiratoire, à la fréquence cardiaque au repos, aux pas, à l’énergie active et aux entraînements. La saturation en oxygène dépend de la disponibilité d’une mesure physique.

## Validation sur iPhone

- **Projection cardiaque.** Environ 35 000 mesures en attente ont été ramenées à environ 600 candidats à l’export, tout en conservant à ce stade la haute résolution locale. Un essai court a ensuite validé la cadence d’une mesure réelle par minute en arrière-plan.
- **Correction sans doublon.** La correction d’une mesure SDNN a remplacé la valeur précédente dans Santé. La relecture a confirmé un seul objet pour le même identifiant, en version 2.
- **Relecture après mise à jour iOS.** Sous iOS 27.2 bêta 1, les 20 dernières entrées examinées pour chacun des flux fréquence cardiaque, SDNN et sommeil correspondaient aux UUID locaux. Deux entraînements étaient visibles avec des UUID différents de ceux du journal local. Ce point est resté ouvert.
- **Fin du projet.** La purge locale a libéré environ 800 Mo sur l’iPhone. Un contrôle en lecture seule a retrouvé des échantillons historiques dans Santé avant la désinstallation manuelle.

## Explorer le code

- [Normalisation des mesures](Strand/Data/HealthMeasurementNormalizer.swift)
- [Projection et règles de débit](Packages/WhoopStore/Sources/WhoopStore/HealthProjection.swift)
- [Écriture et suivi HealthKit](StrandiOS/Health/HealthKitWriter.swift)
- [Décommissionnement et contrôle en lecture seule](StrandiOS/Health/NoopLocalDecommission.swift)
- [Guide de compilation et état du dépôt](PROJECT.md)

Ce dépôt est une archive de développement. Le projet amont fournit l’application et l’intégration Bluetooth existantes. Les contributions présentées ici portent sur le pipeline iOS vers Santé et ses protections. [Licence](LICENSE) · [Attributions](ATTRIBUTION.md)
