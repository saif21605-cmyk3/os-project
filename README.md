# System Monitor with Docker

A real-time system monitoring dashboard that runs in Docker. It visualizes CPU, GPU, RAM, Disk, and Network metrics in a modern web interface.

## Features

-   **Real-time Monitoring**: CPU usage, Temperature, GPU stats, RAM, Disk, and Network traffic.
-   **Dockerized**: Split into Collector, Reporter (API), and Web (Frontend) containers.
-   **Windows/WSL Support**: Includes a helper script to bridge host hardware metrics (GPU/Temp) to the Docker container.
-   **Historical Data**: Sparkline charts and history tables for metrics over time.
-   **Responsive UI**: Dark mode dashboard built with vanilla HTML/CSS/JS.

## Prerequisites

-   **Docker** and **Docker Compose**
-   **PowerShell** (if running on Windows to collect host metrics)

## Installation & Running

### 1. Clone the Repository

```bash
git clone https://github.com/saif21605-cmyk3/os-project.git
cd os-project
```

### 2. Start Host Metrics Collector (Windows Only)

Since Docker on Windows runs in a VM, it cannot directly access hardware sensors. Run this script in a **PowerShell** window on your host machine to collect GPU and CPU temperature data:

```powershell
powershell -ExecutionPolicy Bypass -File .\export_host_metrics.ps1
```

*Keep this window open or run it in the background.*

### 3. Start Docker Containers

In your terminal (WSL or Command Prompt), run:

```bash
docker-compose up -d --build
```

### 4. Access the Dashboard

Open your browser and navigate to:

[http://localhost](http://localhost)

## Architecture

-   **Collector**: Bash script (`monitor.sh`) collecting metrics from `/proc` and the host JSON file.
-   **Reporter**: Python Flask app (`server.py`) serving the API.
-   **Web**: Nginx container serving the static frontend and proxying API requests.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
