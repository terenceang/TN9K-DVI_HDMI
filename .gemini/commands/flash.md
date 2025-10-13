# Flash Tang Nano 9K HDMI

<!-- To run bash command directly, use the Bash tool -->

<!-- SRAM (default, temporary - lost on power cycle) -->
```bash
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 2 --fsFile "E:\OneDrive\Desktop\FPGA\TN9K+DVI_HDMI\impl\pnr\TN9K_HDMI_Video.fs"
```

<!-- Flash (permanent - survives power cycle) -->
```bash
"C:\Gowin\Gowin_V1.9.12_x64\Programmer\bin\programmer_cli.exe" --device GW1NR-9C --run 5 --fsFile "E:\OneDrive\Desktop\FPGA\TN9K+DVI_HDMI\impl\pnr\TN9K_HDMI_Video.fs"
```