#!/usr/bin/env python3
"""Build a --restore JSON that sets only `whatsNew` (release notes) for
version 1.3 across all 50 App Store Connect locales. The other three
fields are null (= leave untouched). Brand names 'Captured' and
'iCloud' are kept verbatim in every language."""
import json

EN = """What's New in Version 1.3

• Built-in browser: update a saved link to the page you're currently viewing, or reset it back to the original — in one tap.
• See the size of every list and folder at a glance.
• More reliable sharing: items you send to Captured are now captured even when the app is in the background.
• Back up and restore your entire library as a single file.
• Faster, more dependable iCloud sync, with clearer transfer progress and badges.
• Stability improvements and bug fixes.

Thanks for using Captured!"""

FR = """Nouveautés de la version 1.3

• Navigateur intégré : mettez à jour un lien enregistré vers la page que vous consultez, ou réinitialisez-le à l'original — en un seul geste.
• Visualisez d'un coup d'œil la taille de chaque liste et dossier.
• Partage plus fiable : les éléments envoyés vers Captured sont désormais capturés même lorsque l'app est en arrière-plan.
• Sauvegardez et restaurez toute votre bibliothèque dans un seul fichier.
• Synchronisation iCloud plus rapide et plus fiable, avec une progression des transferts et des badges plus clairs.
• Améliorations de stabilité et corrections de bugs.

Merci d'utiliser Captured !"""

DE = """Neu in Version 1.3

• Integrierter Browser: Aktualisiere einen gespeicherten Link auf die gerade geöffnete Seite oder setze ihn mit einem Tippen auf das Original zurück.
• Sieh die Größe jeder Liste und jedes Ordners auf einen Blick.
• Zuverlässigeres Teilen: An Captured gesendete Inhalte werden jetzt auch erfasst, wenn die App im Hintergrund läuft.
• Sichere deine gesamte Bibliothek in einer einzigen Datei und stelle sie wieder her.
• Schnellere, zuverlässigere iCloud-Synchronisierung mit klarerer Übertragungsanzeige und Kennzeichen.
• Stabilitätsverbesserungen und Fehlerbehebungen.

Danke, dass du Captured nutzt!"""

ES = """Novedades de la versión 1.3

• Navegador integrado: actualiza un enlace guardado a la página que estás viendo, o restablécelo al original con un solo toque.
• Consulta el tamaño de cada lista y carpeta de un vistazo.
• Compartir más fiable: los elementos que envías a Captured ahora se capturan incluso con la app en segundo plano.
• Haz una copia de seguridad de toda tu biblioteca y restáurala desde un solo archivo.
• Sincronización con iCloud más rápida y fiable, con un progreso de transferencia y distintivos más claros.
• Mejoras de estabilidad y corrección de errores.

¡Gracias por usar Captured!"""

IT = """Novità della versione 1.3

• Browser integrato: aggiorna un link salvato alla pagina che stai visualizzando o riportalo all'originale con un solo tocco.
• Vedi a colpo d'occhio le dimensioni di ogni elenco e cartella.
• Condivisione più affidabile: gli elementi inviati a Captured vengono ora acquisiti anche quando l'app è in background.
• Esegui il backup dell'intera libreria e ripristinala da un unico file.
• Sincronizzazione iCloud più veloce e affidabile, con avanzamento dei trasferimenti e badge più chiari.
• Miglioramenti della stabilità e correzioni di bug.

Grazie per usare Captured!"""

PT_BR = """Novidades da versão 1.3

• Navegador integrado: atualize um link salvo para a página que você está vendo ou redefina-o para o original com um toque.
• Veja o tamanho de cada lista e pasta rapidamente.
• Compartilhamento mais confiável: os itens enviados ao Captured agora são capturados mesmo com o app em segundo plano.
• Faça backup de toda a sua biblioteca e restaure-a a partir de um único arquivo.
• Sincronização com o iCloud mais rápida e confiável, com progresso de transferência e selos mais claros.
• Melhorias de estabilidade e correções de bugs.

Obrigado por usar o Captured!"""

PT_PT = """Novidades da versão 1.3

• Navegador integrado: atualize uma ligação guardada para a página que está a ver ou reponha-a no original com um toque.
• Veja num relance o tamanho de cada lista e pasta.
• Partilha mais fiável: os itens enviados para o Captured são agora capturados mesmo com a app em segundo plano.
• Faça uma cópia de segurança de toda a sua biblioteca e restaure-a a partir de um único ficheiro.
• Sincronização com o iCloud mais rápida e fiável, com progresso de transferência e emblemas mais claros.
• Melhorias de estabilidade e correções de erros.

Obrigado por usar o Captured!"""

NL = """Nieuw in versie 1.3

• Ingebouwde browser: werk een bewaarde koppeling bij naar de pagina die je nu bekijkt, of zet hem met één tik terug naar het origineel.
• Zie in één oogopslag de grootte van elke lijst en map.
• Betrouwbaarder delen: items die je naar Captured stuurt, worden nu ook vastgelegd als de app op de achtergrond staat.
• Maak een reservekopie van je hele bibliotheek en zet deze terug vanuit één bestand.
• Snellere, betrouwbaardere iCloud-synchronisatie, met duidelijkere overdrachtsvoortgang en symbolen.
• Stabiliteitsverbeteringen en foutoplossingen.

Bedankt dat je Captured gebruikt!"""

DA = """Nyt i version 1.3

• Indbygget browser: opdater et gemt link til den side, du ser lige nu, eller nulstil det til originalen med ét tryk.
• Se størrelsen på hver liste og mappe med et enkelt blik.
• Mere pålidelig deling: emner, du sender til Captured, fanges nu, selv når appen kører i baggrunden.
• Sikkerhedskopiér hele dit bibliotek, og gendan det fra én enkelt fil.
• Hurtigere og mere pålidelig iCloud-synkronisering med tydeligere overførselsforløb og mærker.
• Stabilitetsforbedringer og fejlrettelser.

Tak, fordi du bruger Captured!"""

NO = """Nytt i versjon 1.3

• Innebygd nettleser: oppdater en lagret lenke til siden du ser på nå, eller tilbakestill den til originalen med ett trykk.
• Se størrelsen på hver liste og mappe med et raskt blikk.
• Mer pålitelig deling: elementer du sender til Captured, fanges nå opp selv når appen er i bakgrunnen.
• Sikkerhetskopier hele biblioteket ditt, og gjenopprett det fra én enkelt fil.
• Raskere og mer pålitelig iCloud-synkronisering, med tydeligere overføringsforløp og merker.
• Stabilitetsforbedringer og feilrettinger.

Takk for at du bruker Captured!"""

SV = """Nytt i version 1.3

• Inbyggd webbläsare: uppdatera en sparad länk till sidan du tittar på just nu, eller återställ den till originalet med en tryckning.
• Se storleken på varje lista och mapp med en snabb blick.
• Mer tillförlitlig delning: objekt du skickar till Captured fångas nu även när appen körs i bakgrunden.
• Säkerhetskopiera hela ditt bibliotek och återställ det från en enda fil.
• Snabbare och mer tillförlitlig iCloud-synkronisering, med tydligare överföringsförlopp och märken.
• Stabilitetsförbättringar och buggfixar.

Tack för att du använder Captured!"""

FI = """Uutta versiossa 1.3

• Sisäänrakennettu selain: päivitä tallennettu linkki nykyiselle sivulle tai palauta se alkuperäiseen yhdellä napautuksella.
• Näe jokaisen luettelon ja kansion koko yhdellä silmäyksellä.
• Luotettavampi jakaminen: Capturediin lähettämäsi kohteet tallentuvat nyt myös silloin, kun sovellus on taustalla.
• Varmuuskopioi koko kirjastosi ja palauta se yhdestä tiedostosta.
• Nopeampi ja luotettavampi iCloud-synkronointi, jossa siirron eteneminen ja merkit näkyvät selkeämmin.
• Vakausparannuksia ja virheenkorjauksia.

Kiitos, että käytät Capturedia!"""

PL = """Nowości w wersji 1.3

• Wbudowana przeglądarka: zaktualizuj zapisany link do strony, którą właśnie przeglądasz, lub przywróć go do oryginału jednym dotknięciem.
• Zobacz rozmiar każdej listy i folderu na pierwszy rzut oka.
• Bardziej niezawodne udostępnianie: elementy wysyłane do Captured są teraz zapisywane nawet wtedy, gdy aplikacja działa w tle.
• Utwórz kopię zapasową całej biblioteki i przywróć ją z jednego pliku.
• Szybsza i bardziej niezawodna synchronizacja iCloud z czytelniejszym postępem przesyłania i odznakami.
• Poprawki stabilności i błędów.

Dziękujemy za korzystanie z Captured!"""

CS = """Novinky ve verzi 1.3

• Vestavěný prohlížeč: aktualizujte uložený odkaz na stránku, kterou si právě prohlížíte, nebo jej jedním klepnutím vraťte na původní.
• Podívejte se na velikost každého seznamu a složky na první pohled.
• Spolehlivější sdílení: položky odeslané do Captured se nyní zachytí i tehdy, když je aplikace na pozadí.
• Zálohujte celou knihovnu a obnovte ji z jediného souboru.
• Rychlejší a spolehlivější synchronizace s iCloudem s přehlednějším průběhem přenosu a odznaky.
• Vylepšení stability a opravy chyb.

Děkujeme, že používáte Captured!"""

SK = """Novinky vo verzii 1.3

• Vstavaný prehliadač: aktualizujte uložený odkaz na stránku, ktorú práve prezeráte, alebo ho jedným ťuknutím vráťte na pôvodný.
• Pozrite si veľkosť každého zoznamu a priečinka na prvý pohľad.
• Spoľahlivejšie zdieľanie: položky odoslané do Captured sa teraz zachytia aj vtedy, keď je aplikácia na pozadí.
• Zálohujte celú knižnicu a obnovte ju z jediného súboru.
• Rýchlejšia a spoľahlivejšia synchronizácia s iCloudom s prehľadnejším priebehom prenosu a odznakmi.
• Vylepšenia stability a opravy chýb.

Ďakujeme, že používate Captured!"""

HU = """Újdonságok az 1.3-as verzióban

• Beépített böngésző: frissíts egy mentett hivatkozást az éppen megtekintett oldalra, vagy egyetlen koppintással állítsd vissza az eredetit.
• Lásd minden lista és mappa méretét egy pillantással.
• Megbízhatóbb megosztás: a Capturednek küldött elemek mostantól akkor is rögzülnek, ha az app a háttérben fut.
• Készíts biztonsági mentést a teljes könyvtáradról, és állítsd vissza egyetlen fájlból.
• Gyorsabb és megbízhatóbb iCloud-szinkronizálás, áttekinthetőbb átviteli folyamattal és jelvényekkel.
• Stabilitási fejlesztések és hibajavítások.

Köszönjük, hogy a Capturedet használod!"""

RO = """Noutăți în versiunea 1.3

• Browser integrat: actualizează un link salvat la pagina pe care o vizualizezi sau readu-l la original cu o singură atingere.
• Vezi dimensiunea fiecărei liste și a fiecărui dosar dintr-o privire.
• Partajare mai fiabilă: elementele trimise către Captured sunt acum capturate chiar și când aplicația este în fundal.
• Fă o copie de rezervă a întregii biblioteci și restaureaz-o dintr-un singur fișier.
• Sincronizare iCloud mai rapidă și mai fiabilă, cu progres al transferului și insigne mai clare.
• Îmbunătățiri de stabilitate și remedieri de erori.

Îți mulțumim că folosești Captured!"""

HR = """Novosti u verziji 1.3

• Ugrađeni preglednik: ažurirajte spremljenu poveznicu na stranicu koju trenutačno gledate ili je jednim dodirom vratite na izvornu.
• Vidite veličinu svakog popisa i mape na prvi pogled.
• Pouzdanije dijeljenje: stavke poslane u Captured sada se bilježe čak i kad je aplikacija u pozadini.
• Sigurnosno kopirajte cijelu knjižnicu i vratite je iz jedne datoteke.
• Brža i pouzdanija iCloud sinkronizacija s jasnijim napretkom prijenosa i značkama.
• Poboljšanja stabilnosti i ispravci pogrešaka.

Hvala što koristite Captured!"""

SL = """Novosti v različici 1.3

• Vgrajeni brskalnik: posodobite shranjeno povezavo na stran, ki si jo trenutno ogledujete, ali jo z enim dotikom ponastavite na izvirno.
• Na prvi pogled si oglejte velikost vsakega seznama in mape.
• Zanesljivejša skupna raba: elementi, poslani v Captured, se zdaj zajamejo tudi, ko je aplikacija v ozadju.
• Varnostno kopirajte celotno knjižnico in jo obnovite iz ene same datoteke.
• Hitrejša in zanesljivejša sinhronizacija z iCloudom z jasnejšim potekom prenosa in značkami.
• Izboljšave stabilnosti in odprava napak.

Hvala, ker uporabljate Captured!"""

EL = """Τι νέο υπάρχει στην έκδοση 1.3

• Ενσωματωμένο πρόγραμμα περιήγησης: ενημερώστε έναν αποθηκευμένο σύνδεσμο στη σελίδα που βλέπετε ή επαναφέρετέ τον στον αρχικό με ένα άγγιγμα.
• Δείτε με μια ματιά το μέγεθος κάθε λίστας και φακέλου.
• Πιο αξιόπιστη κοινή χρήση: τα στοιχεία που στέλνετε στο Captured καταγράφονται τώρα ακόμη και όταν η εφαρμογή είναι στο παρασκήνιο.
• Δημιουργήστε αντίγραφο ασφαλείας ολόκληρης της βιβλιοθήκης σας και επαναφέρετέ την από ένα μόνο αρχείο.
• Ταχύτερος και πιο αξιόπιστος συγχρονισμός iCloud, με σαφέστερη πρόοδο μεταφοράς και σήματα.
• Βελτιώσεις σταθερότητας και διορθώσεις σφαλμάτων.

Ευχαριστούμε που χρησιμοποιείτε το Captured!"""

TR = """Sürüm 1.3'teki yenilikler

• Yerleşik tarayıcı: kayıtlı bir bağlantıyı görüntülediğiniz sayfaya güncelleyin ya da tek dokunuşla özgün haline döndürün.
• Her listenin ve klasörün boyutunu bir bakışta görün.
• Daha güvenilir paylaşım: Captured'a gönderdiğiniz öğeler artık uygulama arka plandayken bile yakalanıyor.
• Tüm kitaplığınızı yedekleyin ve tek bir dosyadan geri yükleyin.
• Daha hızlı ve daha güvenilir iCloud eşitlemesi; daha net aktarım ilerlemesi ve rozetlerle.
• Kararlılık iyileştirmeleri ve hata düzeltmeleri.

Captured'ı kullandığınız için teşekkürler!"""

RU = """Что нового в версии 1.3

• Встроенный браузер: обновите сохранённую ссылку на текущую страницу или верните её к исходной одним касанием.
• Смотрите размер каждого списка и папки с первого взгляда.
• Более надёжный обмен: объекты, отправленные в Captured, теперь сохраняются, даже когда приложение работает в фоне.
• Создавайте резервную копию всей библиотеки и восстанавливайте её из одного файла.
• Более быстрая и надёжная синхронизация с iCloud, с понятным ходом передачи и значками.
• Улучшения стабильности и исправления ошибок.

Спасибо, что используете Captured!"""

UK = """Що нового у версії 1.3

• Вбудований браузер: оновіть збережене посилання на сторінку, яку ви переглядаєте, або поверніть його до початкового одним дотиком.
• Переглядайте розмір кожного списку та папки з першого погляду.
• Надійніший обмін: елементи, надіслані до Captured, тепер зберігаються навіть коли програма працює у фоні.
• Створюйте резервну копію всієї бібліотеки та відновлюйте її з одного файлу.
• Швидша й надійніша синхронізація з iCloud із зрозумілішим перебігом передавання та значками.
• Покращення стабільності та виправлення помилок.

Дякуємо, що користуєтеся Captured!"""

HE = """מה חדש בגרסה 1.3

• דפדפן מובנה: עדכנו קישור שמור לדף שאתם צופים בו, או אפסו אותו למקור בנגיעה אחת.
• ראו במבט אחד את הגודל של כל רשימה ותיקייה.
• שיתוף אמין יותר: פריטים שאתם שולחים אל Captured נלכדים כעת גם כשהאפליקציה פועלת ברקע.
• גבו את כל הספרייה שלכם ושחזרו אותה מקובץ יחיד.
• סנכרון iCloud מהיר ואמין יותר, עם התקדמות העברה ותגים ברורים יותר.
• שיפורי יציבות ותיקוני באגים.

תודה שאתם משתמשים ב-Captured!"""

AR = """الجديد في الإصدار 1.3

• متصفّح مدمج: حدّث رابطًا محفوظًا إلى الصفحة التي تعرضها الآن، أو أعِده إلى الأصل بنقرة واحدة.
• اطّلع على حجم كل قائمة ومجلد بنظرة سريعة.
• مشاركة أكثر موثوقية: العناصر التي ترسلها إلى Captured تُلتقط الآن حتى عندما يكون التطبيق في الخلفية.
• انسخ مكتبتك بالكامل احتياطيًا واستعدها من ملف واحد.
• مزامنة iCloud أسرع وأكثر موثوقية، مع تقدّم نقل وشارات أوضح.
• تحسينات في الاستقرار وإصلاحات للأخطاء.

شكرًا لاستخدامك Captured!"""

UR = """ورژن 1.3 میں نیا کیا ہے

• بلٹ اِن براؤزر: محفوظ شدہ لنک کو اُس صفحے پر اپ ڈیٹ کریں جو آپ دیکھ رہے ہیں، یا ایک ٹیپ سے اسے اصل پر بحال کریں۔
• ہر فہرست اور فولڈر کا حجم ایک نظر میں دیکھیں۔
• زیادہ قابلِ اعتماد اشتراک: Captured کو بھیجی گئی اشیاء اب ایپ کے پس منظر میں ہونے پر بھی محفوظ ہو جاتی ہیں۔
• اپنی پوری لائبریری کا بیک اپ لیں اور اسے ایک ہی فائل سے بحال کریں۔
• تیز تر اور زیادہ قابلِ اعتماد iCloud مطابقت پذیری، واضح تر منتقلی پیش رفت اور بیجز کے ساتھ۔
• استحکام میں بہتری اور بگ کی اصلاحات۔

Captured استعمال کرنے کا شکریہ!"""

HI = """वर्शन 1.3 में नया क्या है

• बिल्ट-इन ब्राउज़र: सहेजे गए लिंक को उस पेज पर अपडेट करें जिसे आप देख रहे हैं, या एक टैप में उसे मूल पर रीसेट करें।
• हर सूची और फ़ोल्डर का आकार एक नज़र में देखें।
• अधिक भरोसेमंद शेयरिंग: Captured को भेजे गए आइटम अब ऐप के बैकग्राउंड में होने पर भी कैप्चर हो जाते हैं।
• अपनी पूरी लाइब्रेरी का बैकअप लें और उसे एक ही फ़ाइल से पुनर्स्थापित करें।
• तेज़ और अधिक भरोसेमंद iCloud सिंक, स्पष्ट ट्रांसफ़र प्रगति और बैज के साथ।
• स्थिरता सुधार और बग फ़िक्स।

Captured का उपयोग करने के लिए धन्यवाद!"""

BN = """সংস্করণ 1.3-এ নতুন কী

• বিল্ট-ইন ব্রাউজার: সংরক্ষিত একটি লিঙ্ক আপনি যে পৃষ্ঠাটি দেখছেন সেটিতে আপডেট করুন, অথবা এক ট্যাপে এটি মূল অবস্থায় ফিরিয়ে আনুন।
• প্রতিটি তালিকা ও ফোল্ডারের আকার এক নজরে দেখুন।
• আরও নির্ভরযোগ্য শেয়ারিং: Captured-এ পাঠানো আইটেমগুলি এখন অ্যাপ ব্যাকগ্রাউন্ডে থাকলেও সংরক্ষিত হয়।
• আপনার পুরো লাইব্রেরি ব্যাকআপ করুন এবং একটি একক ফাইল থেকে পুনরুদ্ধার করুন।
• দ্রুততর ও আরও নির্ভরযোগ্য iCloud সিঙ্ক, স্পষ্টতর ট্রান্সফার অগ্রগতি ও ব্যাজ সহ।
• স্থিতিশীলতার উন্নতি ও বাগ সংশোধন।

Captured ব্যবহার করার জন্য ধন্যবাদ!"""

GU = """વર્ઝન 1.3 માં નવું શું છે

• બિલ્ટ-ઇન બ્રાઉઝર: સાચવેલી લિંકને તમે જોઈ રહ્યા છો તે પૃષ્ઠ પર અપડેટ કરો, અથવા એક ટૅપમાં તેને મૂળ પર રીસેટ કરો.
• દરેક સૂચિ અને ફોલ્ડરનું કદ એક નજરમાં જુઓ.
• વધુ વિશ્વસનીય શેરિંગ: Captured પર મોકલેલી આઇટમ્સ હવે ઍપ બૅકગ્રાઉન્ડમાં હોય ત્યારે પણ કૅપ્ચર થાય છે.
• તમારી સંપૂર્ણ લાઇબ્રેરીનો બૅકઅપ લો અને એક જ ફાઇલમાંથી તેને પુનઃસ્થાપિત કરો.
• ઝડપી અને વધુ વિશ્વસનીય iCloud સિંક, સ્પષ્ટ ટ્રાન્સફર પ્રગતિ અને બૅજ સાથે.
• સ્થિરતા સુધારાઓ અને બગ ફિક્સ.

Captured વાપરવા બદલ આભાર!"""

KN = """ಆವೃತ್ತಿ 1.3 ರಲ್ಲಿ ಹೊಸತೇನು

• ಅಂತರ್ನಿರ್ಮಿತ ಬ್ರೌಸರ್: ಉಳಿಸಿದ ಲಿಂಕ್ ಅನ್ನು ನೀವು ನೋಡುತ್ತಿರುವ ಪುಟಕ್ಕೆ ನವೀಕರಿಸಿ, ಅಥವಾ ಒಂದೇ ಟ್ಯಾಪ್‌ನಲ್ಲಿ ಅದನ್ನು ಮೂಲಕ್ಕೆ ಮರುಹೊಂದಿಸಿ.
• ಪ್ರತಿ ಪಟ್ಟಿ ಮತ್ತು ಫೋಲ್ಡರ್‌ನ ಗಾತ್ರವನ್ನು ಒಂದೇ ನೋಟದಲ್ಲಿ ನೋಡಿ.
• ಹೆಚ್ಚು ವಿಶ್ವಾಸಾರ್ಹ ಹಂಚಿಕೆ: Captured ಗೆ ಕಳುಹಿಸಿದ ಐಟಂಗಳು ಈಗ ಅಪ್ಲಿಕೇಶನ್ ಹಿನ್ನೆಲೆಯಲ್ಲಿದ್ದರೂ ಸೆರೆಹಿಡಿಯಲಾಗುತ್ತದೆ.
• ನಿಮ್ಮ ಸಂಪೂರ್ಣ ಲೈಬ್ರರಿಯನ್ನು ಬ್ಯಾಕಪ್ ಮಾಡಿ ಮತ್ತು ಒಂದೇ ಫೈಲ್‌ನಿಂದ ಮರುಸ್ಥಾಪಿಸಿ.
• ವೇಗದ ಮತ್ತು ಹೆಚ್ಚು ವಿಶ್ವಾಸಾರ್ಹ iCloud ಸಿಂಕ್, ಸ್ಪಷ್ಟ ವರ್ಗಾವಣೆ ಪ್ರಗತಿ ಮತ್ತು ಬ್ಯಾಡ್ಜ್‌ಗಳೊಂದಿಗೆ.
• ಸ್ಥಿರತೆ ಸುಧಾರಣೆಗಳು ಮತ್ತು ದೋಷ ಪರಿಹಾರಗಳು.

Captured ಬಳಸಿದ್ದಕ್ಕೆ ಧನ್ಯವಾದಗಳು!"""

ML = """പതിപ്പ് 1.3-ലെ പുതിയത്

• ബിൽറ്റ്-ഇൻ ബ്രൗസർ: സംരക്ഷിച്ച ലിങ്ക് നിങ്ങൾ കാണുന്ന പേജിലേക്ക് അപ്‌ഡേറ്റ് ചെയ്യുക, അല്ലെങ്കിൽ ഒറ്റ ടാപ്പിൽ അത് യഥാർത്ഥത്തിലേക്ക് പുനഃസജ്ജമാക്കുക.
• ഓരോ ലിസ്റ്റിന്റെയും ഫോൾഡറിന്റെയും വലുപ്പം ഒറ്റ നോട്ടത്തിൽ കാണുക.
• കൂടുതൽ വിശ്വസനീയമായ പങ്കിടൽ: Captured-ലേക്ക് അയയ്ക്കുന്ന ഇനങ്ങൾ ഇപ്പോൾ ആപ്പ് പശ്ചാത്തലത്തിലായിരിക്കുമ്പോഴും ക്യാപ്ചർ ചെയ്യപ്പെടുന്നു.
• നിങ്ങളുടെ മുഴുവൻ ലൈബ്രറിയും ബാക്കപ്പ് ചെയ്ത് ഒറ്റ ഫയലിൽ നിന്ന് പുനഃസ്ഥാപിക്കുക.
• വേഗതയേറിയതും കൂടുതൽ വിശ്വസനീയവുമായ iCloud സിങ്ക്, വ്യക്തമായ ട്രാൻസ്ഫർ പുരോഗതിയും ബാഡ്ജുകളും.
• സ്ഥിരത മെച്ചപ്പെടുത്തലുകളും ബഗ് പരിഹാരങ്ങളും.

Captured ഉപയോഗിച്ചതിന് നന്ദി!"""

MR = """आवृत्ती 1.3 मध्ये नवीन काय आहे

• अंगभूत ब्राउझर: जतन केलेली लिंक तुम्ही पाहत असलेल्या पृष्ठावर अपडेट करा, किंवा एका टॅपमध्ये ती मूळवर रीसेट करा.
• प्रत्येक सूची आणि फोल्डरचा आकार एका दृष्टीक्षेपात पाहा.
• अधिक विश्वासार्ह शेअरिंग: Captured ला पाठवलेले आयटम आता ॲप पार्श्वभूमीत असतानाही कॅप्चर होतात.
• तुमच्या संपूर्ण लायब्ररीचा बॅकअप घ्या आणि एकाच फाइलमधून पुनर्संचयित करा.
• जलद आणि अधिक विश्वासार्ह iCloud सिंक, स्पष्ट हस्तांतरण प्रगती आणि बॅजसह.
• स्थिरता सुधारणा आणि बग दुरुस्त्या.

Captured वापरल्याबद्दल धन्यवाद!"""

OR = """ସଂସ୍କରଣ 1.3 ରେ ନୂଆ କଣ

• ବିଲ୍ଟ-ଇନ୍ ବ୍ରାଉଜର୍: ସଂରକ୍ଷିତ ଲିଙ୍କକୁ ଆପଣ ଦେଖୁଥିବା ପୃଷ୍ଠାକୁ ଅପଡେଟ୍ କରନ୍ତୁ, କିମ୍ବା ଗୋଟିଏ ଟାପ୍‌ରେ ଏହାକୁ ମୂଳକୁ ରିସେଟ୍ କରନ୍ତୁ।
• ପ୍ରତ୍ୟେକ ତାଲିକା ଏବଂ ଫୋଲ୍ଡରର ଆକାର ଏକ ନଜରରେ ଦେଖନ୍ତୁ।
• ଅଧିକ ନିର୍ଭରଯୋଗ୍ୟ ସେୟାରିଂ: Captured କୁ ପଠାଯାଇଥିବା ଆଇଟମ୍‌ଗୁଡ଼ିକ ବର୍ତ୍ତମାନ ଆପ୍ ପୃଷ୍ଠପଟରେ ଥିଲେ ବି କ୍ୟାପଚର୍ ହୁଏ।
• ଆପଣଙ୍କ ସମ୍ପୂର୍ଣ୍ଣ ଲାଇବ୍ରେରୀର ବ୍ୟାକଅପ୍ ନିଅନ୍ତୁ ଏବଂ ଗୋଟିଏ ଫାଇଲରୁ ଏହାକୁ ପୁନଃସ୍ଥାପନ କରନ୍ତୁ।
• ଶୀଘ୍ର ଏବଂ ଅଧିକ ନିର୍ଭରଯୋଗ୍ୟ iCloud ସିଙ୍କ, ସ୍ପଷ୍ଟ ସ୍ଥାନାନ୍ତର ପ୍ରଗତି ଏବଂ ବ୍ୟାଜ୍ ସହିତ।
• ସ୍ଥିରତା ଉନ୍ନତି ଏବଂ ବଗ୍ ସମାଧାନ।

Captured ବ୍ୟବହାର କରିଥିବାରୁ ଧନ୍ୟବାଦ!"""

PA = """ਵਰਜਨ 1.3 ਵਿੱਚ ਨਵਾਂ ਕੀ ਹੈ

• ਬਿਲਟ-ਇਨ ਬ੍ਰਾਊਜ਼ਰ: ਸੰਭਾਲੇ ਲਿੰਕ ਨੂੰ ਉਸ ਪੰਨੇ 'ਤੇ ਅੱਪਡੇਟ ਕਰੋ ਜੋ ਤੁਸੀਂ ਦੇਖ ਰਹੇ ਹੋ, ਜਾਂ ਇੱਕ ਟੈਪ ਨਾਲ ਇਸਨੂੰ ਅਸਲੀ 'ਤੇ ਰੀਸੈੱਟ ਕਰੋ।
• ਹਰ ਸੂਚੀ ਅਤੇ ਫੋਲਡਰ ਦਾ ਆਕਾਰ ਇੱਕ ਨਜ਼ਰ ਵਿੱਚ ਦੇਖੋ।
• ਵਧੇਰੇ ਭਰੋਸੇਯੋਗ ਸਾਂਝਾਕਰਨ: Captured ਨੂੰ ਭੇਜੀਆਂ ਆਈਟਮਾਂ ਹੁਣ ਐਪ ਬੈਕਗ੍ਰਾਊਂਡ ਵਿੱਚ ਹੋਣ 'ਤੇ ਵੀ ਕੈਪਚਰ ਹੁੰਦੀਆਂ ਹਨ।
• ਆਪਣੀ ਪੂਰੀ ਲਾਇਬ੍ਰੇਰੀ ਦਾ ਬੈਕਅੱਪ ਲਓ ਅਤੇ ਇੱਕੋ ਫਾਈਲ ਤੋਂ ਇਸਨੂੰ ਬਹਾਲ ਕਰੋ।
• ਤੇਜ਼ ਅਤੇ ਵਧੇਰੇ ਭਰੋਸੇਯੋਗ iCloud ਸਿੰਕ, ਸਪਸ਼ਟ ਟ੍ਰਾਂਸਫਰ ਪ੍ਰਗਤੀ ਅਤੇ ਬੈਜਾਂ ਨਾਲ।
• ਸਥਿਰਤਾ ਸੁਧਾਰ ਅਤੇ ਬੱਗ ਫਿਕਸ।

Captured ਵਰਤਣ ਲਈ ਧੰਨਵਾਦ!"""

TA = """பதிப்பு 1.3 இல் புதியது

• உள்ளமைந்த உலாவி: சேமித்த இணைப்பை நீங்கள் பார்க்கும் பக்கத்திற்குப் புதுப்பிக்கவும், அல்லது ஒரே தட்டலில் அதை அசலுக்கு மீட்டமைக்கவும்.
• ஒவ்வொரு பட்டியல் மற்றும் கோப்புறையின் அளவை ஒரே பார்வையில் காணுங்கள்.
• நம்பகமான பகிர்வு: Captured க்கு அனுப்பப்படும் உருப்படிகள் இப்போது ஆப் பின்னணியில் இருக்கும்போதும் சேமிக்கப்படுகின்றன.
• உங்கள் முழு நூலகத்தையும் காப்புப் பிரதி எடுத்து ஒரே கோப்பிலிருந்து மீட்டமைக்கவும்.
• வேகமான மற்றும் நம்பகமான iCloud ஒத்திசைவு, தெளிவான பரிமாற்ற முன்னேற்றம் மற்றும் பேட்ஜ்களுடன்.
• நிலைத்தன்மை மேம்பாடுகள் மற்றும் பிழை திருத்தங்கள்.

Captured ஐப் பயன்படுத்தியதற்கு நன்றி!"""

TE = """వెర్షన్ 1.3 లో కొత్తది

• అంతర్నిర్మిత బ్రౌజర్: సేవ్ చేసిన లింక్‌ను మీరు చూస్తున్న పేజీకి అప్‌డేట్ చేయండి, లేదా ఒకే ట్యాప్‌తో దాన్ని అసలుకు రీసెట్ చేయండి.
• ప్రతి జాబితా మరియు ఫోల్డర్ పరిమాణాన్ని ఒక్క చూపులో చూడండి.
• మరింత నమ్మదగిన భాగస్వామ్యం: Captured కు పంపిన అంశాలు ఇప్పుడు యాప్ నేపథ్యంలో ఉన్నప్పుడు కూడా క్యాప్చర్ అవుతాయి.
• మీ మొత్తం లైబ్రరీని బ్యాకప్ చేసి, ఒకే ఫైల్ నుండి పునరుద్ధరించండి.
• వేగవంతమైన మరియు మరింత నమ్మదగిన iCloud సింక్, స్పష్టమైన బదిలీ పురోగతి మరియు బ్యాడ్జ్‌లతో.
• స్థిరత్వ మెరుగుదలలు మరియు బగ్ పరిష్కారాలు.

Captured ఉపయోగించినందుకు ధన్యవాదాలు!"""

TH = """มีอะไรใหม่ในเวอร์ชัน 1.3

• เบราว์เซอร์ในตัว: อัปเดตลิงก์ที่บันทึกไว้ให้เป็นหน้าที่คุณกำลังดูอยู่ หรือรีเซ็ตกลับเป็นต้นฉบับได้ในแตะเดียว
• ดูขนาดของทุกรายการและโฟลเดอร์ได้ในพริบตา
• การแชร์ที่เชื่อถือได้มากขึ้น: รายการที่คุณส่งไปยัง Captured จะถูกบันทึกแม้ขณะที่แอปทำงานอยู่เบื้องหลัง
• สำรองข้อมูลทั้งคลังของคุณและกู้คืนจากไฟล์เดียว
• การซิงค์ iCloud ที่เร็วและเชื่อถือได้มากขึ้น พร้อมความคืบหน้าการถ่ายโอนและป้ายที่ชัดเจนยิ่งขึ้น
• การปรับปรุงความเสถียรและการแก้ไขข้อบกพร่อง

ขอบคุณที่ใช้ Captured!"""

VI = """Có gì mới trong phiên bản 1.3

• Trình duyệt tích hợp: cập nhật liên kết đã lưu thành trang bạn đang xem, hoặc đặt lại về bản gốc chỉ với một chạm.
• Xem kích thước của mọi danh sách và thư mục trong nháy mắt.
• Chia sẻ đáng tin cậy hơn: các mục bạn gửi đến Captured giờ đây được lưu ngay cả khi ứng dụng chạy nền.
• Sao lưu toàn bộ thư viện và khôi phục từ một tệp duy nhất.
• Đồng bộ iCloud nhanh và đáng tin cậy hơn, với tiến trình truyền và huy hiệu rõ ràng hơn.
• Cải thiện độ ổn định và sửa lỗi.

Cảm ơn bạn đã sử dụng Captured!"""

ID = """Yang baru di versi 1.3

• Browser bawaan: perbarui tautan tersimpan ke halaman yang sedang Anda lihat, atau atur ulang ke aslinya dengan satu ketukan.
• Lihat ukuran setiap daftar dan folder secara sekilas.
• Berbagi lebih andal: item yang Anda kirim ke Captured kini tetap ditangkap meski aplikasi berjalan di latar belakang.
• Cadangkan seluruh pustaka Anda dan pulihkan dari satu berkas.
• Sinkronisasi iCloud yang lebih cepat dan andal, dengan kemajuan transfer dan lencana yang lebih jelas.
• Peningkatan stabilitas dan perbaikan bug.

Terima kasih telah menggunakan Captured!"""

MS = """Apa yang baharu dalam versi 1.3

• Pelayar terbina dalam: kemas kini pautan yang disimpan ke halaman yang sedang anda lihat, atau tetapkan semula ke asal dengan satu ketikan.
• Lihat saiz setiap senarai dan folder secara sepintas lalu.
• Perkongsian lebih boleh dipercayai: item yang anda hantar ke Captured kini ditangkap walaupun apl berada di latar belakang.
• Sandarkan seluruh pustaka anda dan pulihkannya daripada satu fail.
• Penyegerakan iCloud yang lebih pantas dan boleh dipercayai, dengan kemajuan pemindahan dan lencana yang lebih jelas.
• Penambahbaikan kestabilan dan pembaikan pepijat.

Terima kasih kerana menggunakan Captured!"""

CA = """Novetats de la versió 1.3

• Navegador integrat: actualitza un enllaç desat a la pàgina que estàs veient, o restableix-lo a l'original amb un sol toc.
• Mira la mida de cada llista i carpeta d'un cop d'ull.
• Compartició més fiable: els elements que envies a Captured ara es capturen fins i tot amb l'app en segon pla.
• Fes una còpia de seguretat de tota la biblioteca i restaura-la des d'un únic fitxer.
• Sincronització amb l'iCloud més ràpida i fiable, amb un progrés de transferència i distintius més clars.
• Millores d'estabilitat i correccions d'errors.

Gràcies per fer servir Captured!"""

JA = """バージョン1.3の新機能

• 内蔵ブラウザ：保存したリンクを今見ているページに更新したり、ワンタップで元に戻したりできます。
• すべてのリストとフォルダのサイズをひと目で確認できます。
• より確実な共有：Capturedに送った項目は、アプリがバックグラウンドにあるときでも取り込まれるようになりました。
• ライブラリ全体を1つのファイルにバックアップして復元できます。
• より速く、より安定したiCloud同期。転送の進行状況とバッジも見やすくなりました。
• 安定性の向上とバグ修正。

Capturedをご利用いただきありがとうございます！"""

KO = """버전 1.3의 새로운 기능

• 내장 브라우저: 저장한 링크를 현재 보고 있는 페이지로 업데이트하거나 한 번의 탭으로 원래대로 되돌릴 수 있습니다.
• 모든 목록과 폴더의 크기를 한눈에 확인하세요.
• 더 안정적인 공유: Captured로 보낸 항목이 이제 앱이 백그라운드에 있을 때도 캡처됩니다.
• 전체 라이브러리를 하나의 파일로 백업하고 복원하세요.
• 더 빠르고 안정적인 iCloud 동기화, 더 명확한 전송 진행률과 배지 제공.
• 안정성 개선 및 버그 수정.

Captured를 이용해 주셔서 감사합니다!"""

ZH_HANS = """1.3 版本新功能

• 内置浏览器：将已保存的链接更新为你正在浏览的页面，或一键重置为原始链接。
• 一眼查看每个列表和文件夹的大小。
• 更可靠的分享：发送到 Captured 的内容现在即使在应用处于后台时也能被捕获。
• 将整个资料库备份并从单个文件恢复。
• 更快、更可靠的 iCloud 同步，传输进度和标记更清晰。
• 稳定性改进和错误修复。

感谢你使用 Captured！"""

ZH_HANT = """1.3 版本新功能

• 內建瀏覽器：將已儲存的連結更新為你正在瀏覽的頁面，或一鍵重設為原始連結。
• 一眼查看每個列表和檔案夾的大小。
• 更可靠的分享：傳送到 Captured 的內容現在即使在 App 處於背景時也能被擷取。
• 將整個資料庫備份並從單一檔案還原。
• 更快、更可靠的 iCloud 同步，傳輸進度和標記更清晰。
• 穩定性改進和錯誤修正。

感謝你使用 Captured！"""

# Map each App Store Connect locale code → its release-notes text.
WHATS_NEW = {
    "ar-SA": AR, "bn-BD": BN, "ca": CA, "cs": CS, "da": DA, "de-DE": DE,
    "el": EL, "en-AU": EN, "en-CA": EN, "en-GB": EN, "en-US": EN,
    "es-ES": ES, "es-MX": ES, "fi": FI, "fr-CA": FR, "fr-FR": FR,
    "gu-IN": GU, "he": HE, "hi": HI, "hr": HR, "hu": HU, "id": ID,
    "it": IT, "ja": JA, "kn-IN": KN, "ko": KO, "ml-IN": ML, "mr-IN": MR,
    "ms": MS, "nl-NL": NL, "no": NO, "or-IN": OR, "pa-IN": PA, "pl": PL,
    "pt-BR": PT_BR, "pt-PT": PT_PT, "ro": RO, "ru": RU, "sk": SK,
    "sl-SI": SL, "sv": SV, "ta-IN": TA, "te-IN": TE, "th": TH, "tr": TR,
    "uk": UK, "ur-PK": UR, "vi": VI, "zh-Hans": ZH_HANS, "zh-Hant": ZH_HANT,
}

doc = {
    "appId": "6763560506",
    "versionString": "1.3",
    "platform": "IOS",
    "localizations": {
        code: {"promotionalText": None, "description": None,
               "keywords": None, "whatsNew": text}
        for code, text in WHATS_NEW.items()
    },
}

# Length sanity check (Apple limit: 4000).
over = [(c, len(t)) for c, t in WHATS_NEW.items() if len(t) > 4000]
assert not over, f"Over 4000 chars: {over}"
print(f"{len(WHATS_NEW)} locales, max len = {max(len(t) for t in WHATS_NEW.values())} chars")

with open("appstore-1.3-whatsnew.json", "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
print("Wrote appstore-1.3-whatsnew.json")
