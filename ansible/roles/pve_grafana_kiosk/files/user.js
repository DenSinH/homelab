// Disable crash restore & session restore
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.enabled", false);
user_pref("browser.sessionstore.interval", 0);
user_pref("browser.startup.page", 0);
user_pref("browser.startup.homepage_override.mstone", "ignore");

// Disable crash reporting & telemetry
user_pref("toolkit.crashreporter.enabled", false);
user_pref("toolkit.crashreporter.prompt", false);
user_pref("toolkit.startup.max_resumed_crashes", -1);
user_pref("browser.tabs.crashReporting.sendReport", false);
user_pref("browser.crashReports.unsubmittedCheck.enabled", false);

// Disable telemetry / health reports
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.server", "");
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("toolkit.telemetry.shutdownPingSender.enabled", false);
user_pref("toolkit.telemetry.bhrPing.enabled", false);
user_pref("toolkit.telemetry.newProfilePing.enabled", false);
user_pref("toolkit.telemetry.updatePing.enabled", false);

// Disable animations and smooth scrolling
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("general.smoothScroll", false);
user_pref("layout.css.scroll-behavior.spring-constant.low", 0);

// Disable tabs animations
user_pref("browser.tabs.animate", false);
user_pref("browser.fullscreen.animateUp", 0);

// Reduce DNS / network overhead
user_pref("network.http.pipelining", true);
user_pref("network.http.pipelining.maxrequests", 8);
user_pref("network.http.proxy.pipelining", true);
user_pref("network.http.fast-fallback-to-IPv4", true);

// Increase cache to reduce reloads
user_pref("browser.cache.disk.enable", true);
user_pref("browser.cache.memory.enable", true);
user_pref("browser.cache.memory.capacity", 65536); // 64 MB RAM cache
user_pref("browser.cache.disk.capacity", 1048576); // 1 GB disk cache

// Disable Pocket, built-in PDF viewer, and update prompts
user_pref("extensions.pocket.enabled", false);
user_pref("pdfjs.disabled", true);
user_pref("app.update.auto", false);
user_pref("app.update.enabled", false);
user_pref("browser.aboutHomeSnippets.updateUrl", "");
user_pref("browser.shell.checkDefaultBrowser", false);

// Disable "What's New" / tips / onboarding
user_pref("browser.onboarding.enabled", false);
user_pref("browser.startup.homepage_welcome_url", "about:blank");
user_pref("browser.startup.homepage_welcome_url.additional", "");

// Force fullscreen without prompts
user_pref("full-screen-api.warning.delay", 0);
user_pref("full-screen-api.warning.timeout", 0);

// Disable popups / alerts
user_pref("dom.disable_open_during_load", true);
user_pref("dom.webnotifications.enabled", false);
user_pref("dom.push.enabled", false);
