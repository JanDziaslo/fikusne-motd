# MOTD zrobione za pomoca prostych skryptow bash
## Wszytkie skrypty były testowane na Debianie 13
#### MOTD pierwszy
Nie potrzebuje żadnej konfiguracji zadziała od strzała (a przynajmniej powinien) 

Zależności potrzebne do odpalenia:
- toilet
##### Przykładowy wygląd
![Przykładowy wygląd](img/pierwszy-motd.png)
#### MOTD drugi
Domyślnie wyświetla tylko dysk który jest zamontowany w "/" jeżeli chcesz więcej dysków zmodyfikuj tablice w linijce 63 podmieniajac przykładowe punkty montowania na te które cię interesują np. "/mnt/dysk2"

Zależności potrzebne do odpalenia:
- toilet
##### Przykładowy wygląd
![Przykładowy wygląd](img/drugi-motd.png)

## Instalacja MOTD

```bash
sudo ./install.sh --motd drugi-motd.sh --install-deps
```

Flagi:
- `--motd pierwszy-motd|drugi-motd` – wybór wersji (domyślnie `drugi-motd`)
- `--install-deps` – doinstaluj `toilet`, `lsb-release` (wymaga `apt-get`)

Po instalacji MOTD jest dostępny jako `/etc/update-motd.d/10-motd-custom`.
