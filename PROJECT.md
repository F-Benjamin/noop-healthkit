# NOOP → Apple Santé

Dépôt local de reprise du fork NOOP. Le bracelet WHOOP fournit les mesures via Bluetooth. NOOP les traite localement, puis projette les flux compatibles vers HealthKit pour leur consultation dans Santé et, le cas échéant, par Bevel.

Le dépôt conserve la projection de fréquence cardiaque par contexte, les garde-fous d’export, la rétention locale et le code de décommissionnement. L’installation précédente a été retirée de l’iPhone.

## Reprendre le développement

1. Installer Xcode avec le SDK iOS et XcodeGen.
2. Générer le projet avec `xcodegen generate --spec project.yml`.
3. Ouvrir `Strand.xcodeproj` et compiler le schéma `NOOPiOS`. Pour signer sur iPhone, créer le fichier local ignoré à partir de `Config/BundleIdSecrets.example.xcconfig` et choisir son équipe Apple.
4. Pour les essais HealthKit, utiliser une installation de développement et vérifier les autorisations dans Santé.

Les résultats d’audit issus de l’iPhone, les bases locales et les réglages privés de signature sont exclus. La licence et les attributions amont sont conservées. Le dépôt amont est configuré pour la récupération seule.
