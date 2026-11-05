-- Объекты администрации (F3 → «Объекты», 2026-11-04): серверные props OPEN//77, сохраняются в БД
-- (rp_objects) и ставятся заново при каждом старте ресурса. Удаляются только из той же вкладки.

ObjectsConfig = {
    permission = "rp.objects",  -- право rp_core: ставить, двигать, удалять объекты и проверять коллизию
    spawnDistance = 8,          -- новый объект — не дальше от админа, метров (место присылает клиент)
    editDistance = 40,          -- двигать и удалять — объекты не дальше, метров
    moveLimit = 30,             -- за одно перемещение — не дальше от прежнего места, метров
    listRadius = 150,           -- во вкладке — объекты в этом радиусе
    listMax = 60,               -- и не больше стольких (ближайшие)
    ticketSeconds = 300,        -- перемещение гизмо — столько действует разрешение сервера
    streamingRadius = 150,      -- с какого расстояния объект видят игроки, метров

    -- Каталог объектов: имена (alias) платформы OPEN//77 — тот же список, что в системной
    -- панели open77_admin (shared/config.lua), без race.* (служебные). Коллизия у каждого
    -- проверяется в игре (кнопка «Проверить коллизию»), результат — в БД (rp_object_collision):
    -- ставить можно только объекты с подтверждённой коллизией.
    models = {
        "furniture.chair.metal", "furniture.chair.plastic", "furniture.stool.metal", "furniture.stool.bar",
        "furniture.bench.wood", "furniture.bench.metal", "furniture.bench.outdoor", "furniture.bench.wall",
        "furniture.table.industrial", "furniture.table.lab", "furniture.table.outdoor",
        "furniture.table.bar", "furniture.counter.bar", "furniture.sofa.poor", "furniture.bed.single",
        "furniture.shelf.industrial", "furniture.cabinet.industrial", "furniture.cabinet.glass",
        "furniture.tv_stand",
        "office.desk", "office.desk.corpo", "office.chair", "office.chair.corpo", "office.cabinet.file",
        "office.reception_desk",
        "kitchen.counter", "kitchen.fridge", "kitchen.fridge.poor", "kitchen.stove",
        "kitchen.coffee_machine",
        "bathroom.toilet", "bathroom.shower", "bathroom.mirror",
        "crate.small", "crate.valuable", "crate.delivery", "crate.delivery.tall", "crate.cargo",
        "crate.cardboard", "crate.ammo_box",
        "container.barrel", "container.locker", "container.safe", "container.toolbox", "container.ammo_case",
        "container.keg", "container.gas_tank", "container.gas_can", "container.water_jug",
        "container.bucket", "container.freight", "container.shipping",
        "barrier.concrete", "barrier.blockade.wide", "barrier.blockade.mechanical", "barrier.hesco",
        "barrier.gate.swinging", "barrier.pedestrian", "barrier.road", "barrier.road.jersey",
        "barrier.roadblock.concrete", "barrier.tire_blocker",
        "fence.railing", "fence.railing.industrial", "fence.railing.balcony", "fence.wire.reinforcement",
        "sign.rect.blank", "sign.rect.keep_out", "sign.arrow.left", "sign.street", "sign.homeless",
        "sign.kiosk_frame",
        "street.lamp", "street.lamp.neomilitary", "street.hydrant", "street.parking_meter",
        "street.traffic_light", "street.newspaper_stand", "street.electrical_pole", "street.electrical_box",
        "street.awning", "street.water_tower", "street.ac_unit",
        "bin.dumpster.large", "bin.dumpster.small", "bin.dumpster.medium", "bin.trash_can",
        "bin.trash_can.small",
        "garbage.bag", "garbage.cardboard_pile", "garbage.street_trash", "garbage.industrial_trash",
        "garbage.mattress",
        "debris.pile", "debris.corrugated_sheet", "debris.construction_pile", "debris.sand_pile",
        "debris.rebar",
        "pallet.wood", "pallet.wood.loaded", "pallet.stack",
        "industrial.forklift", "industrial.pallet_truck", "industrial.fire_extinguisher",
        "industrial.trolley", "industrial.cart", "industrial.generator", "industrial.gas_pump",
        "industrial.shop_rack", "industrial.machine", "industrial.vent.rooftop", "industrial.vent.shaft",
        "pipe.small", "pipe.medium", "pipe.round", "pipe.waste",
        "electronics.monitor", "electronics.monitor.device", "electronics.tv.16x9", "electronics.tv.21x9",
        "electronics.tv.neokitsch.16x9", "electronics.tv.neokitsch.21x9", "electronics.tv.screen.16x9",
        "electronics.tv.screen.21x9", "electronics.tv.screen.neokitsch.16x9",
        "electronics.tv.screen.neokitsch.21x9", "electronics.tv.large", "electronics.monitor.device.a",
        "electronics.monitor.device.b", "electronics.monitor.device.c", "electronics.monitor.device.d",
        "electronics.monitor.device.e", "electronics.monitor.screen.a", "electronics.monitor.screen.b",
        "electronics.monitor.screen.c", "electronics.monitor.screen.d",
        "electronics.monitor.screen.a.vertical", "electronics.monitor.screen.b.vertical",
        "electronics.monitor.screen.c.vertical", "electronics.monitor.screen.d.vertical",
        "electronics.screen.21x9", "electronics.screen.16x9", "electronics.screen.4x3",
        "electronics.screen.3x4", "electronics.screen.9x16", "electronics.screen.9x21",
        "electronics.screen.2x1", "electronics.frame.a", "electronics.frame.ab", "electronics.frame.ac",
        "electronics.frame.ad", "electronics.frame.ae", "electronics.frame.af",
        "electronics.monitor.surveillance", "electronics.vending_machine",
        "electronics.vending_machine.small", "electronics.vending_machine.drink", "electronics.arcade",
        "electronics.jukebox", "electronics.server", "electronics.cash_register", "electronics.fuse_box",
        "electronics.camera", "electronics.air_conditioner",
        "light.lantern.japanese", "light.lantern.chinese", "light.ceiling", "light.fluorescent",
        "light.spotlight", "light.desk", "light.hanging", "light.candle", "light.disco_ball",
        "vegetation.planter.large", "vegetation.planter.city", "vegetation.flower_pot",
        "vegetation.flower_pot.kitsch", "vegetation.palm_attachment",
        "market.stand", "market.stand.small", "market.kiosk", "market.shelf.chinese",
        "market.cabinet.chinese",
        "food.street_food", "food.soda_can", "food.drink_packaged", "food.snack", "food.bourbon",
        "food.beer_tap",
        "medical.cart", "medical.iv_stand", "medical.monitor_arm", "medical.device", "medical.container",
        "medical.morgue_table", "medical.body_bag",
        "military.case", "military.case.large", "military.weapon_rack", "military.checkpoint",
        "military.security_gate",
        "door.swinging_gate", "door.elevator", "door.glass", "door.shuttle",
        "recreation.billiard_table", "recreation.roulette_table", "recreation.gym_equipment",
        "recreation.tent", "recreation.sleeping_bag",
        "music.guitar.electric", "music.amplifier", "music.piano",
        "decor.sculpture.arasaka", "decor.sculpture.chinese", "decor.painting", "decor.vase.large",
        "tool.shovel", "tool.welder", "tool.fire_axe",
    },
}
