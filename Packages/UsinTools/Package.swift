// swift-tools-version:5.10
import PackageDescription

// Инструменты Mac для Usin (бывший Singluse): чёлка, голосовой ввод, буфер обмена, плавная мышь,
// превью в Dock, живые обои, встречи, ИИ-сервисы, виджеты и панель в строке меню.
// Собирается только для Mac; приложение подключает его с фильтром платформы.
let package = Package(
    name: "UsinTools",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UsinTools", targets: ["UsinTools"]),
    ],
    dependencies: [
        // Закреплено точной версией: стороннее обновление не попадёт в сборку без проверки.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        // Parakeet от NVIDIA через FluidAudio (Apache 2.0): вторая модель распознавания, быстрее Whisper и точнее на русском.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(name: "UsinToolsCore"),
        .target(
            name: "UsinTools",
            dependencies: [
                "UsinToolsCore",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(name: "UsinToolsCoreTests", dependencies: ["UsinToolsCore"]),
    ]
)
