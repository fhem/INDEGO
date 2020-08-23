##INDEGO
###Define
    define <name> INDEGO <email> [<poll-interval>]
Der Wert für poll-interval ist optional, wenn er nicht angegeben wird, wird ein Abfrageintervall von 5 Minuten eingestellt.

##Set
Folgende Set-Aufrufe werden unterstützt
* `actionInterval` - Poll-Interval für den aktiven Betrieb (Mowing/Paused/Returning)
* `operatingData` - liefert Batteriedaten und die Gartengröße
* `password` - das Passwort muss natürlich nur einmal gesetzt werden

###Weblink
    define <nameWl> weblink htmlCode { FHEM::INDEGO::ShowMap("<name>") }

###Tablet UI
Eine Einbindung ins Tablet UI funktioniert per Html Snippet:

    <div data-type="iframe" data-src="../../fhem/INDEGO/<device>/map/450" data-fill="yes" data-device="<device>" data-get="mapsvgcache_ts"></div>
\<device> ist durch den Gerätenamen zu ersetzen.
Die Zahl am Ende der URL gibt die Breite des Bildes an.
Die Angabe der Breite ist optional.
Zusätzlich kann die URL aber auch noch um eine Höhe ergänzt werden, also

    ...fhem/INDEGO/\<device>/map/800/600
Dann wird die Kartengrafik mit 800x600 Pixeln generiert.
