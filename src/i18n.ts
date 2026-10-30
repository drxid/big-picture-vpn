import { computed, ref } from "vue";

export type Lang = "ru" | "en";

const STORAGE_LANG = "bpvpn.lang";

const ru = {
  htmlLocale: "ru-RU",
  languageName: "Русский",

  headlineChecking: "Проверяю",
  headlineConnecting: "Подключаю",
  headlineDisconnecting: "Отключаю",
  headlineOn: "Защищено",
  headlineOff: "Без защиты",

  sublineChecking: "Читаю состояние туннелей",
  sublineBusy: "Это займёт пару секунд",
  sublineOff: "Трафик идёт напрямую, без туннеля",
  routePrefix: "Трафик идёт через ",

  cardConnecting: "Подключаю",
  cardDisconnecting: "Отключаю",
  cardRunning: "Работает",
  cardStopped: "Остановлен",

  emptyTitle: "Туннелей нет",
  emptyNote:
    "Не нашёл ни Happ, ни конфигов AmneziaWG. Если конфиги есть, переустанови приложение: так восстановится служебная задача.",

  actionSelect: "Выбрать",
  actionConnect: "Подключить",
  actionDisconnect: "Выключить",
  actionChange: "Изменить",
  actionOpen: "Открыть",
  actionExit: "Выйти",
  actionClose: "Закрыть",
  actionQuit: "Выход",
  actionHold: "Не отпускай",
  actionStart: "Начать",
  menu: "Меню",
  pressAnyButton: "Нажми любую кнопку на геймпаде",

  menuOrder: "Первым показывать",
  menuAutoConnect: "Автозапуск VPN",
  menuScheme: "Кнопки геймпада",
  menuLanguage: "Язык",
  menuAbout: "О приложении",
  menuExit: "Выйти из приложения",
  on: "Включён",
  off: "Выключен",
  orderName: "По алфавиту",
  orderRunning: "Работающий",

  welcomeTitle: "VPN прямо из Big Picture",
  welcomeLead:
    "Окно VPN-клиента и запрос UAC не нажать с геймпада: они остаются на рабочем столе, позади полноэкранного режима. Это приложение включает и выключает VPN с геймпада, не выходя из Big Picture.",
  welcomeSearching: "Ищу",
  welcomeMissing: "Не найден",
  welcomeInstalled: "Установлен",
  welcomeConfigs: (count: number) => `Конфигов: ${count}`,
  welcomeNoClients: "Поставь AmneziaWG или Happ и запусти приложение снова.",
  welcomeSteam:
    "Добавь приложение в Steam как стороннюю игру и включи Ввод Steam, чтобы запускать его из Big Picture.",

  restored: (name: string) => `Вернул «${name}».`,
  restoreFailed: (name: string) => `Вернуть «${name}» тоже не вышло.`,
};

type Messages = typeof ru;

const en: Messages = {
  htmlLocale: "en-US",
  languageName: "English",

  headlineChecking: "Checking",
  headlineConnecting: "Connecting",
  headlineDisconnecting: "Disconnecting",
  headlineOn: "Protected",
  headlineOff: "Not protected",

  sublineChecking: "Reading tunnel status",
  sublineBusy: "This takes a couple of seconds",
  sublineOff: "Traffic goes directly, with no tunnel",
  routePrefix: "Traffic goes through ",

  cardConnecting: "Connecting",
  cardDisconnecting: "Disconnecting",
  cardRunning: "Running",
  cardStopped: "Stopped",

  emptyTitle: "No tunnels",
  emptyNote:
    "Found neither Happ nor any AmneziaWG configs. If you do have configs, reinstall the app to restore its background task.",

  actionSelect: "Select",
  actionConnect: "Connect",
  actionDisconnect: "Turn off",
  actionChange: "Change",
  actionOpen: "Open",
  actionExit: "Exit",
  actionClose: "Close",
  actionQuit: "Exit",
  actionHold: "Keep holding",
  actionStart: "Start",
  menu: "Menu",
  pressAnyButton: "Press any button on the gamepad",

  menuOrder: "Show first",
  menuAutoConnect: "Connect on launch",
  menuScheme: "Gamepad buttons",
  menuLanguage: "Language",
  menuAbout: "About",
  menuExit: "Exit the app",
  on: "On",
  off: "Off",
  orderName: "Alphabetical",
  orderRunning: "Running",

  welcomeTitle: "VPN right inside Big Picture",
  welcomeLead:
    "A VPN client's window and its UAC prompt can't be reached with a gamepad: they stay on the desktop, behind the fullscreen view. This app switches your VPN on and off from the gamepad, without leaving Big Picture.",
  welcomeSearching: "Searching",
  welcomeMissing: "Not found",
  welcomeInstalled: "Installed",
  welcomeConfigs: (count: number) => `Configs: ${count}`,
  welcomeNoClients: "Install AmneziaWG or Happ, then start the app again.",
  welcomeSteam:
    "Add the app to Steam as a non-Steam game and enable Steam Input to launch it from Big Picture.",

  restored: (name: string) => `Restored “${name}”.`,
  restoreFailed: (name: string) => `Could not restore “${name}” either.`,
};

const MESSAGES: Record<Lang, Messages> = { ru, en };

export const LANGS: Lang[] = ["ru", "en"];

/// A saved choice wins. Until there is one the system decides, and WebView2
/// reports the Windows display language here.
function initialLang(): Lang {
  const saved = localStorage.getItem(STORAGE_LANG);
  if (saved === "ru" || saved === "en") return saved;
  return navigator.language.toLowerCase().startsWith("ru") ? "ru" : "en";
}

export const lang = ref<Lang>(initialLang());
export const t = computed(() => MESSAGES[lang.value]);

document.documentElement.lang = lang.value;

export function setLang(value: Lang) {
  lang.value = value;
  localStorage.setItem(STORAGE_LANG, value);
  document.documentElement.lang = value;
}

export function languageName(value: Lang) {
  return MESSAGES[value].languageName;
}
