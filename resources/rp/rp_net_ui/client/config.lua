-- Устройства мира (решение владельца 2026-11-05): отключить игровые подсказки всего, с чем можно
-- взаимодействовать, кроме дверей и лифтов. «Отключить всё» платформа не умеет, поэтому:
--   1) список классов ниже отключается сразу при входе;
--   2) класс любого другого устройства, на которое игрок смотрит вблизи, отключается на лету
--      и запоминается на этом ПК (Open77.kvp), — если он не похож на дверь или лифт (keep).
-- Свой класс — без подстановок: Open77.world.setDeviceInteractionEnabled сверяет имя объекта
-- и его ControllerPS без учёта регистра.

NetUiConfig = {
    -- Не трогать: дверь, лифт, ворота КПП (open77_doors, elevators). Подстрока имени класса.
    keep = { "door", "lift", "elevator" },

    -- Компьютеры: вместо игровой подсказки — «Подключиться» (экран NetOS).
    computers = { "Computer" },
    -- Почтоматы: «Забрать заказы» (заказы с сайтов корпораций, rp_net).
    dropPoints = { "DropPoint" },

    -- Отключаются сразу (классы устройств Cyberpunk 2077; неизвестное имя просто ничего не делает).
    disable = {
        "Computer", "Terminal", "DropPoint", "ATM", "VendingMachine", "IceMachine", "WeaponVendingMachine",
        "Jukebox", "Radio", "TV", "Speaker", "ArcadeMachine", "PachinkoMachine", "SmartWindow", "LcdScreen",
        "Stillage", "ConfessionBooth", "NetrunnerChair", "MaintenancePanel", "ElectricBox", "ElectricLight",
        "DataTerm", "Fridge", "Toilet", "WashingMachine", "SmokeMachine", "Fan", "Crane", "Window",
        "Blind", "Speedbump", "Billboard", "InteractiveSign", "ForkliftDevice", "Reflector", "ChestPress",
        "WeakFence", "FuseBox", "Coder", "Wardrobe", "Stash", "Bed", "Sink", "Shower", "Mirror",
        "HoloDevice", "HoloFeeder", "MovableDevice", "FakeDoor", "DisposalDevice", "BlindingLight",
        "CoffeeMachine", "Television", "ExplosiveDevice", "SecurityAlarm", "SecurityLocker", "ToggleDevice",
    },

    -- Сколько отдельных устройств (по id движка, если класс не определился) держать отключёнными.
    maxEntityPolicies = 180,
    -- Наезд камеры на монитор: расстояние до экрана (м), FOV, длительность (мс).
    camDistance = 0.62,
    camFov = 52,
    camBlendMs = 650,
}
