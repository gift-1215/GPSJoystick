# GPS 搖桿

Mac 上的 iPhone 定位測試原型。用滑鼠拖曳畫面搖桿或按鍵盤方向鍵，即可控制地圖上的模擬位置。

## 先在 Mac 上試用

1. 解壓縮後開啟 `GPSJoystick.app`。最低部署版本為 macOS 14。注意：套件內附的預先編譯 App 僅含 Apple 晶片（arm64）版本；Intel Mac（例如 Core i7）請先依下方「原始碼」一節重新編譯成 Universal 版本再使用。
2. 預設從台北 101 開始。按「選擇起點」再點地圖，可跳到新的起點。用加減按鈕縮放，用「回到模擬位置」將地圖置中。
3. 拖曳搖桿或按方向鍵，即可朝該方向以設定速度移動。放開後會繼續前進。按搖桿右側的「暫停」可停在目前位置，再按「開始」繼續。選擇新起點時也會暫停移動。
4. 速度滑桿可設定移動速度（0–120 km/h）。步行、單車和開車分別為 5、18 和 50 km/h。
5. 地圖上方的「搜尋地點」可查地址、地標或店家。選取結果可先預覽位置，再按「設為起點」。已開啟定位同步時，新起點也會送到 iPhone。

## 模擬步數

1. 在 Mac 右側的「模擬步數」開啟「累計步數」。時速大於 0 且不超過 8 公里時，App 會依移動距離和設定的步幅計算步數。預設步幅為 75 公分。暫停、選擇新起點或切到單車／開車預設時會停止累計。
2. 若要匯入 iPhone 的「健康」，用 Xcode 開啟 `Source/iPhone/GPSJoystickSteps.xcodeproj`。在 **Signing & Capabilities** 選擇有 HealthKit 權限的開發團隊。若 Bundle Identifier 已被使用，改成你團隊的唯一識別碼。選擇已信任這台 Mac 且已開啟開發者模式的 iPhone（iOS 17 以上），按 **Run** 安裝「GPS 搖桿步數」。
3. 在 Mac 開啟「藍牙同步至 iPhone」，展開「顯示 iPhone 配對碼」。第一次使用時，在 iPhone 的「GPS 搖桿步數」按「掃描 Mac 配對碼」，掃描 Mac 畫面上的 QR 碼。也可以從 Mac 複製配對碼，在手機貼上。
4. 在手機按「開始同步」，允許藍牙與「步數」寫入權限。兩端使用配對碼加密步數資料。連線後可以切換到其他 App。若強制關閉配套 App，請重新開啟並按「開始同步」。
5. 步數約每 2 秒分批送出，暫停或關閉累計時也會送出目前一批。未同步的批次會保留在 Mac，可在重新連線後繼續匯入。在「健康」搜尋「步數」，可從「顯示所有資料」查看由「GPS 搖桿步數」寫入的紀錄。
6. 要測試連線，在 Mac 的「模擬步數」按「傳送 2,000 測試步」。搖桿暫停時也能使用。每按一次會加入一批 2,000 步，尚未連線時會保留待同步。iPhone 寫入「健康」後，Mac 會顯示「iPhone 已確認寫入測試步數」。

步數同步走藍牙，可獨立於 USB 定位同步使用。

## 透過 USB 同步定位到 iPhone

1. 用可傳資料的 USB 線接上 iPhone（iOS 17 以上）並解鎖。若尚未配對，在 Finder 選取 iPhone，並在手機上點選「信任」。
2. 在 iPhone 開啟「設定 → 隱私權與安全性 → 開發者模式」。如果看不到選項，先在 Xcode 的 Device Hub（部分版本稱為 Devices and Simulators）配對手機。依 iPhone 畫面上的指示完成重新啟動與確認。
3. 在 GPS 搖桿按「安裝連線元件」。終端機會在使用者的應用程式支援目錄建立 Python 虛擬環境，並從 PyPI 安裝固定版本的 `pymobiledevice3`。需能連上 PyPI，並可執行 Python 3.9 以上。預設採用 Mac 的 `/usr/bin/python3`，有需要可用 `GPS_JOYSTICK_PYTHON` 指定其他 Python。
4. 終端機顯示安裝完成後，回到 GPS 搖桿按「連接 iPhone」，接著按「開始同步位置」。這時 Mac 會送出地圖目前的座標，並在移動時持續更新。
5. 測試結束，按「恢復定位」再拔線。若曾意外拔線，請接回同一支手機，再按「連接 iPhone」與「恢復定位」。如果「恢復定位」顯示失敗，請確認手機已解鎖、USB 已接妥後重試。

這版把速度用來計算每次座標應移動的距離。送到 iPhone 的資料為經緯度，App 讀到的 Core Location 速度欄位可能和控制台的數值不同。移動方向以地圖的北方為準，地圖上的軌跡依座標繪製。

## 原始碼

`Source` 包含 Mac App、iPhone 配套 App 和 Python 定位連線程式。已安裝 Xcode 或支援的命令列工具時，可在解壓縮目錄重新編譯 Mac App。

```sh
./Source/build.sh "$PWD/GPSJoystick-Local.app"
```

預設會編譯 Universal 版本（arm64 + x86_64），可同時在 Apple 晶片與 Intel Mac（例如 Core i7，需 macOS 14 以上）執行。只需要 Intel 版本時可指定架構：

```sh
GPS_JOYSTICK_ARCHS="x86_64" ./Source/build.sh "$PWD/GPSJoystick-Local.app"
```

- [Apple 的 iPhone 開發者模式說明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [pymobiledevice3 的 DVT 定位模擬介面](https://doronz88.github.io/pymobiledevice3/latest/api/dvt/#pymobiledevice3.services.dvt.instruments.location_simulation.LocationSimulation)
