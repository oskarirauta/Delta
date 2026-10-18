import Foundation
import Network
import Combine
import ZIPFoundation

struct ActiveUploadInfo: Equatable {
    let filename: String
    var receivedBytes: Int
    let totalBytes: Int
    
    var progress: Double {
        totalBytes > 0 ? min(1.0, Double(receivedBytes) / Double(totalBytes)) : 0
    }
}

class ROMWebServer: ObservableObject {
    static let shared = ROMWebServer()
    
    @Published var isRunning = false
    @Published var serverAddress: String = "Starting..."
    @Published var lastUploadedFileName: String?
    @Published var activeUpload: ActiveUploadInfo?
    @Published var isEmulating: Bool = false
    
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080
    
    init() {
        start()
    }
    
    func start() {
        guard listener == nil else { return }
        
        do {
            let parameters = NWParameters.tcp
            let newListener = try NWListener(using: parameters, on: port)
            
            newListener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        let ip = self?.getWiFiAddress() ?? "appletv.local"
                        self?.serverAddress = "http://\(ip):8080"
                        print("[ROMWebServer] Ready at \(self?.serverAddress ?? "")")
                    case .failed(let error):
                        print("[ROMWebServer] Failed: \(error)")
                        self?.isRunning = false
                        self?.serverAddress = "Error starting server"
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            
            newListener.start(queue: .main)
            self.listener = newListener
        } catch {
            print("[ROMWebServer] Could not create listener: \(error)")
            self.serverAddress = "Unavailable"
        }
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        
        var receivedData = Data()
        
        func readNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data = data, !data.isEmpty {
                    receivedData.append(data)
                    
                    // Check if headers have arrived
                    if let headerEnd = receivedData.range(of: Data("\r\n\r\n".utf8)) {
                        let headerData = receivedData.subdata(in: 0..<headerEnd.lowerBound)
                        guard let headerString = String(data: headerData, encoding: .utf8) else {
                            connection.cancel()
                            return
                        }
                        
                        let lines = headerString.components(separatedBy: "\r\n")
                        let requestLine = lines.first ?? ""
                        let parts = requestLine.components(separatedBy: " ")
                        let method = parts.first ?? "GET"
                        let fullPath = parts.count > 1 ? parts[1] : "/"
                        let path = fullPath.components(separatedBy: "?").first ?? fullPath
                        
                        if self.isEmulating {
                            self.sendErrorResponse(to: connection, message: "Emulation is currently in progress. ROM transfers are only permitted from the main library screen.", statusCode: 503)
                            return
                        }
                        
                        if method == "GET" && path == "/" {
                            self.sendHTMLPage(to: connection)
                            return
                        } else if method == "GET" && path == "/api/games" {
                            self.sendGamesList(to: connection)
                            return
                        } else if (method == "POST" || method == "GET") && path == "/api/delete" {
                            self.handleDelete(fullPath: fullPath, body: receivedData.subdata(in: headerEnd.upperBound..<receivedData.count), connection: connection)
                            return
                        } else if method == "POST" && path == "/upload-file" {
                            let initial = receivedData.subdata(in: headerEnd.upperBound..<receivedData.count)
                            receivedData.removeAll()
                            self.receiveFile(headers: lines, path: fullPath, initial: initial, connection: connection)
                            return
                        } else if method == "POST" && path == "/upload" {
                            // Extract Content-Length
                            var contentLength = 0
                            for line in lines {
                                if line.lowercased().hasPrefix("content-length:") {
                                    let val = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                                    contentLength = Int(val) ?? 0
                                }
                            }
                            
                            guard contentLength > 0, contentLength <= 64 * 1024 * 1024 else {
                                self.sendErrorResponse(to: connection, message: "Large uploads require /upload-file?filename=NAME with a raw file body and Content-Length.")
                                return
                            }
                            let bodyStartIndex = headerEnd.upperBound
                            let bodyReceivedSoFar = receivedData.count - bodyStartIndex
                            
                            if contentLength <= 0 || bodyReceivedSoFar >= contentLength {
                                let bodyData = receivedData.subdata(in: bodyStartIndex..<receivedData.count)
                                self.processUpload(headers: lines, body: bodyData, connection: connection)
                            } else {
                                // Wait for remaining body bytes
                                func readRemainingBody() {
                                    let remaining = contentLength - (receivedData.count - bodyStartIndex)
                                    connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 65536)) { moreData, _, isDone, readErr in
                                        if let moreData = moreData {
                                            receivedData.append(moreData)
                                        }
                                        if (receivedData.count - bodyStartIndex) >= contentLength || isDone || readErr != nil {
                                            let fullBody = receivedData.subdata(in: bodyStartIndex..<receivedData.count)
                                            self.processUpload(headers: lines, body: fullBody, connection: connection)
                                        } else {
                                            readRemainingBody()
                                        }
                                    }
                                }
                                readRemainingBody()
                            }
                            return
                        } else {
                            self.send404(to: connection)
                            return
                        }
                    }
                }
                
                if receivedData.count > 65536 {
                    connection.cancel()
                    return
                }
                if !isComplete && error == nil {
                    readNext()
                } else {
                    connection.cancel()
                }
            }
        }
        
        readNext()
    }
    
    private func receiveFile(headers: [String], path: String, initial: Data, connection: NWConnection) {
        let components = URLComponents(string: "http://localhost" + path)
        let filename = components?.queryItems?.first(where: { $0.name == "filename" })?.value ?? ""
        let length = headers.first(where: { $0.lowercased().hasPrefix("content-length:") })?
            .split(separator: ":", maxSplits: 1).last.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let upload: TVROMUpload
        do {
            upload = try TVROMUpload(directory: TVGameManager.shared.romsDirectory, filename: filename, expectedBytes: length)
            try upload.append(initial)
            DispatchQueue.main.async {
                self.activeUpload = ActiveUploadInfo(filename: filename, receivedBytes: initial.count, totalBytes: length)
            }
        } catch {
            DispatchQueue.main.async { self.activeUpload = nil }
            sendErrorResponse(to: connection, message: "Invalid upload: \(error.localizedDescription)")
            return
        }
        func receiveNext() {
            if upload.receivedBytes == upload.expectedBytes {
                do {
                    try upload.finish()
                    DispatchQueue.main.async { self.activeUpload = nil }
                    self.finishUpload(at: upload.destination, size: upload.receivedBytes, connection: connection)
                } catch {
                    DispatchQueue.main.async { self.activeUpload = nil }
                    self.sendErrorResponse(to: connection, message: "Upload failed: \(error.localizedDescription)")
                }
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(65536, upload.expectedBytes - upload.receivedBytes)) { data, _, complete, error in
                do {
                    if let data { try upload.append(data) }
                    let current = upload.receivedBytes
                    DispatchQueue.main.async {
                        self.activeUpload?.receivedBytes = current
                    }
                    guard error == nil, !complete || upload.receivedBytes == upload.expectedBytes else { throw CocoaError(.fileReadCorruptFile) }
                    receiveNext()
                } catch {
                    DispatchQueue.main.async { self.activeUpload = nil }
                    self.sendErrorResponse(to: connection, message: "Upload interrupted: \(error.localizedDescription)")
                }
            }
        }
        receiveNext()
    }

    private func finishUpload(at url: URL, size: Int, connection: NWConnection) {
        if url.pathExtension.lowercased() == "zip" {
            do {
                try FileManager.default.unzipItem(at: url, to: TVGameManager.shared.romsDirectory)
                try? FileManager.default.removeItem(at: url)
            } catch { print("[ROMWebServer] ZIP extraction error: \(error)") }
        }
        DispatchQueue.main.async {
            self.lastUploadedFileName = url.lastPathComponent
            TVGameManager.shared.loadGames()
        }
        sendJSONResponse(to: connection, status: "OK", filename: url.lastPathComponent, size: size)
    }

    private func processUpload(headers: [String], body: Data, connection: NWConnection) {
        // Extract boundary without stripping leading hyphens
        var boundary: String?
        for line in headers {
            if let range = line.range(of: "boundary=", options: .caseInsensitive) {
                var rawBoundary = String(line[range.upperBound...])
                if let semi = rawBoundary.range(of: ";") {
                    rawBoundary = String(rawBoundary[..<semi.lowerBound])
                }
                // Trim only quotes and whitespace - preserve leading dashes!
                boundary = rawBoundary.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\""))
            }
        }
        
        guard let boundary = boundary,
              let filename = extractFilename(from: body),
              let fileData = extractFileData(from: body, boundary: boundary) else {
            self.sendErrorResponse(to: connection, message: "Invalid upload: Could not parse multipart form data.")
            return
        }
        
        do {
            let upload = try TVROMUpload(directory: TVGameManager.shared.romsDirectory, filename: filename, expectedBytes: fileData.count)
            try upload.append(fileData)
            try upload.finish()
            self.finishUpload(at: upload.destination, size: fileData.count, connection: connection)
        } catch {
            self.sendErrorResponse(to: connection, message: "Upload failed: \(error.localizedDescription)")
        }
    }

    private func extractFilename(from data: Data) -> String? {
        guard let text = String(data: data.prefix(4096), encoding: .isoLatin1) else { return nil }
        if let range = text.range(of: "filename=\"") {
            let rest = text[range.upperBound...]
            if let endRange = rest.range(of: "\"") {
                let name = String(rest[..<endRange.lowerBound])
                let sanitized = name.replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                return sanitized.isEmpty ? nil : sanitized
            }
        }
        return nil
    }
    
    private func extractFileData(from data: Data, boundary: String) -> Data? {
        let boundaryPrefix = Data(("--" + boundary).utf8)
        let headerEndData = Data("\r\n\r\n".utf8)
        
        guard let firstBoundaryRange = data.range(of: boundaryPrefix) else { return nil }
        guard let headerEndRange = data.range(of: headerEndData, in: firstBoundaryRange.upperBound..<data.count) else { return nil }
        
        let fileContentStart = headerEndRange.upperBound
        let endBoundaryPrefix = Data(("\r\n--" + boundary).utf8)
        
        if let endBoundaryRange = data.range(of: endBoundaryPrefix, in: fileContentStart..<data.count) {
            return data.subdata(in: fileContentStart..<endBoundaryRange.lowerBound)
        } else {
            return data.subdata(in: fileContentStart..<data.count)
        }
    }
    
    private func sendGamesList(to connection: NWConnection) {
        let files = TVGameManager.shared.listAllFilesDetails()
        guard let jsonData = try? JSONSerialization.data(withJSONObject: files, options: [.prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            sendErrorResponse(to: connection, message: "Could not serialize files list")
            return
        }
        
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(jsonString.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r
        \(jsonString)
        """
        
        connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func handleDelete(fullPath: String, body: Data, connection: NWConnection) {
        var filenameToDelete: String?
        
        // 1. Try URL parameter ?file=...
        if let queryRange = fullPath.range(of: "?") {
            let query = String(fullPath[queryRange.upperBound...])
            for param in query.components(separatedBy: "&") {
                let kv = param.components(separatedBy: "=")
                if kv.count == 2 && kv[0] == "file" {
                    filenameToDelete = kv[1].removingPercentEncoding
                }
            }
        }
        
        // 2. Try JSON body
        if filenameToDelete == nil, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            filenameToDelete = json["file"] as? String
        }
        
        guard let targetName = filenameToDelete, !targetName.isEmpty else {
            self.sendErrorResponse(to: connection, message: "Missing file parameter")
            return
        }
        
        do {
            try TVGameManager.shared.deleteFile(named: targetName)
            self.sendJSONResponse(to: connection, status: "DELETED", filename: targetName, size: 0)
        } catch {
            self.sendErrorResponse(to: connection, message: "Delete failed: \(error.localizedDescription)")
        }
    }
    
    private func sendHTMLPage(to connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Delta on Apple TV - ROM Manager</title>
            <style>
                :root {
                    --bg: #0c0e17;
                    --card: #151926;
                    --border: #232b40;
                    --accent-start: #ff5e62;
                    --accent-end: #ff9966;
                    --text: #f1f5f9;
                    --text-muted: #8e9bb0;
                    --nes: #ef4444;
                    --snes: #8b5cf6;
                    --n64: #f59e0b;
                    --success: #10b981;
                }
                * { box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
                body {
                    background: var(--bg);
                    color: var(--text);
                    margin: 0;
                    padding: 30px 16px;
                    display: flex;
                    flex-direction: column;
                    align-items: center;
                }
                .wrap { max-width: 820px; width: 100%; }
                header { text-align: center; margin-bottom: 28px; }
                h1 {
                    margin: 0 0 8px;
                    font-size: 32px;
                    font-weight: 800;
                    background: linear-gradient(135deg, var(--accent-start), var(--accent-end));
                    -webkit-background-clip: text;
                    -webkit-text-fill-color: transparent;
                }
                p.sub { color: var(--text-muted); font-size: 15px; margin: 0; }
                
                .card {
                    background: var(--card);
                    border: 1px solid var(--border);
                    border-radius: 18px;
                    padding: 24px;
                    margin-bottom: 24px;
                    box-shadow: 0 8px 30px rgba(0,0,0,0.4);
                }
                
                .drop-zone {
                    border: 2px dashed #3a4463;
                    border-radius: 14px;
                    padding: 36px 20px;
                    background: #111420;
                    cursor: pointer;
                    text-align: center;
                    transition: all 0.2s ease;
                }
                .drop-zone:hover, .drop-zone.dragover {
                    border-color: var(--accent-start);
                    background: #191e30;
                }
                .icon { font-size: 42px; margin-bottom: 10px; }
                .upload-title { font-size: 18px; font-weight: 700; margin-bottom: 6px; }
                .upload-hint { font-size: 13px; color: var(--text-muted); }
                input[type=file] { display: none; }
                
                .status-box {
                    margin-top: 16px;
                    padding: 12px 16px;
                    border-radius: 10px;
                    font-size: 14px;
                    font-weight: 500;
                    display: none;
                }
                
                .section-header {
                    display: flex;
                    justify-content: space-between;
                    align-items: center;
                    margin-bottom: 16px;
                }
                .section-title { font-size: 20px; font-weight: 700; }
                
                .btn {
                    background: #232b40;
                    color: var(--text);
                    border: 1px solid #3a4463;
                    padding: 8px 16px;
                    border-radius: 8px;
                    font-size: 13px;
                    font-weight: 600;
                    cursor: pointer;
                    transition: background 0.15s;
                }
                .btn:hover { background: #313c59; }
                .btn-delete {
                    background: #3b161c;
                    border: 1px solid #70252b;
                    color: #fca5a5;
                    padding: 6px 12px;
                    border-radius: 6px;
                    font-size: 12px;
                    cursor: pointer;
                }
                .btn-delete:hover { background: #541c24; }
                
                .files-table {
                    width: 100%;
                    border-collapse: collapse;
                    font-size: 14px;
                }
                .files-table th {
                    text-align: left;
                    color: var(--text-muted);
                    font-size: 12px;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                    padding: 10px 12px;
                    border-bottom: 1px solid var(--border);
                }
                .files-table td {
                    padding: 12px;
                    border-bottom: 1px solid #1a2033;
                    vertical-align: middle;
                }
                .files-table tr:hover { background: #191f30; }
                
                .badge {
                    display: inline-block;
                    padding: 3px 8px;
                    border-radius: 6px;
                    font-size: 11px;
                    font-weight: 700;
                    text-transform: uppercase;
                }
                .badge-nes { background: rgba(239, 68, 68, 0.2); color: #f87171; border: 1px solid rgba(239, 68, 68, 0.3); }
                .badge-snes { background: rgba(139, 92, 246, 0.2); color: #c084fc; border: 1px solid rgba(139, 92, 246, 0.3); }
                .badge-n64 { background: rgba(245, 158, 11, 0.2); color: #fbbf24; border: 1px solid rgba(245, 158, 11, 0.3); }
                .badge-other { background: #262c42; color: #94a3b8; }
                
                .file-name { font-weight: 600; color: var(--text); }
                .internal-title { font-size: 12px; color: var(--text-muted); margin-top: 2px; }
                .file-size { color: var(--text-muted); font-family: monospace; font-size: 13px; }
                
                .progress-container {
                    width: 100%;
                    background: #0f172a;
                    border-radius: 8px;
                    overflow: hidden;
                    height: 12px;
                    margin-top: 10px;
                    border: 1px solid #334155;
                }
                .progress-fill {
                    height: 100%;
                    width: 0%;
                    background: linear-gradient(90deg, #38bdf8, #818cf8);
                    transition: width 0.1s ease-out;
                }
                .progress-meta {
                    display: flex;
                    justify-content: space-between;
                    font-size: 12px;
                    color: #94a3b8;
                    margin-top: 6px;
                    font-family: monospace;
                }
            </style>
        </head>
        <body>
            <div class="wrap">
                <header>
                    <h1>Delta for Apple TV</h1>
                    <p class="sub">Wireless Game Library & Storage Manager</p>
                </header>
                
                <!-- Upload Card -->
                <div class="card">
                    <div class="drop-zone" id="dropZone" onclick="document.getElementById('fileInput').click()">
                        <div class="icon">🎮</div>
                        <div class="upload-title">Choose or Drop ROM Files Here</div>
                        <div class="upload-hint">NES · SNES · N64 · GB/GBC · GBA · Mega Drive · DS · GameCube · ZIP archives &amp; cover art</div>
                        <input type="file" id="fileInput" multiple accept="\(TVSystem.uploadExtensions.map { "." + $0 }.joined(separator: ","))">
                    </div>
                    <div id="statusBox" class="status-box"></div>
                </div>
                
                <!-- Installed Games Card -->
                <div class="card">
                    <div class="section-header">
                        <div class="section-title">Received Games on Apple TV</div>
                        <button class="btn" onclick="fetchGames()">🔄 Refresh List</button>
                    </div>
                    <div id="gamesContainer">Loading library...</div>
                </div>
            </div>

            <script>
                const fileInput = document.getElementById('fileInput');
                const dropZone = document.getElementById('dropZone');
                const statusBox = document.getElementById('statusBox');
                const gamesContainer = document.getElementById('gamesContainer');

                ['dragenter', 'dragover'].forEach(name => {
                    dropZone.addEventListener(name, (e) => { e.preventDefault(); dropZone.classList.add('dragover'); });
                });
                ['dragleave', 'drop'].forEach(name => {
                    dropZone.addEventListener(name, (e) => { e.preventDefault(); dropZone.classList.remove('dragover'); });
                });
                dropZone.addEventListener('drop', (e) => {
                    if (e.dataTransfer.files.length) uploadFiles(e.dataTransfer.files);
                });
                fileInput.addEventListener('change', () => {
                    if (fileInput.files.length) uploadFiles(fileInput.files);
                });

                function showStatus(msg, type) {
                    statusBox.style.display = 'block';
                    statusBox.innerText = msg;
                    if (type === 'progress') {
                        statusBox.style.background = '#1e293b';
                        statusBox.style.color = '#38bdf8';
                        statusBox.style.border = '1px solid #38bdf8';
                    } else if (type === 'success') {
                        statusBox.style.background = '#143828';
                        statusBox.style.color = '#4ade80';
                        statusBox.style.border = '1px solid #22c55e';
                    } else {
                        statusBox.style.background = '#3b161c';
                        statusBox.style.color = '#f87171';
                        statusBox.style.border = '1px solid #ef4444';
                    }
                }

                function uploadFile(file) {
                    return new Promise((resolve, reject) => {
                        const xhr = new XMLHttpRequest();
                        const startTime = Date.now();
                        
                        statusBox.style.display = 'block';
                        statusBox.style.background = '#1e293b';
                        statusBox.style.border = '1px solid #38bdf8';
                        statusBox.style.color = '#e2e8f0';
                        statusBox.innerHTML = `
                            <div style="font-weight:600; color:#38bdf8; margin-bottom:4px;">Uploading ${file.name}</div>
                            <div class="progress-container">
                                <div class="progress-fill" id="progressFill"></div>
                            </div>
                            <div class="progress-meta">
                                <span id="progressPercent">0%</span>
                                <span id="progressBytes">0 / ${(file.size / (1024*1024)).toFixed(1)} MB</span>
                                <span id="progressSpeed">-- MB/s</span>
                            </div>
                        `;
                        
                        const progressFill = document.getElementById('progressFill');
                        const progressPercent = document.getElementById('progressPercent');
                        const progressBytes = document.getElementById('progressBytes');
                        const progressSpeed = document.getElementById('progressSpeed');
                        
                        xhr.upload.onprogress = (e) => {
                            if (e.lengthComputable) {
                                const percent = Math.min(100, Math.round((e.loaded / e.total) * 100));
                                const elapsedSec = Math.max(0.1, (Date.now() - startTime) / 1000);
                                const speedMB = (e.loaded / (1024 * 1024)) / elapsedSec;
                                
                                if (progressFill) progressFill.style.width = percent + '%';
                                if (progressPercent) progressPercent.innerText = percent + '%';
                                if (progressBytes) {
                                    const loadedMB = (e.loaded / (1024 * 1024)).toFixed(1);
                                    const totalMB = (e.total / (1024 * 1024)).toFixed(1);
                                    progressBytes.innerText = `${loadedMB} / ${totalMB} MB`;
                                }
                                if (progressSpeed) progressSpeed.innerText = speedMB.toFixed(1) + ' MB/s';
                            }
                        };
                        
                        xhr.onload = () => {
                            if (xhr.status >= 200 && xhr.status < 300) {
                                try {
                                    const json = JSON.parse(xhr.responseText);
                                    if (json.status === 'OK') {
                                        statusBox.style.background = '#143828';
                                        statusBox.style.color = '#4ade80';
                                        statusBox.style.border = '1px solid #22c55e';
                                        statusBox.innerHTML = `✓ <strong>${file.name}</strong> uploaded successfully! Saved to Apple TV storage.`;
                                        resolve(json);
                                    } else {
                                        reject(new Error(json.error || 'Server error'));
                                    }
                                } catch (e) {
                                    reject(e);
                                }
                            } else {
                                reject(new Error(`HTTP ${xhr.status}: ${xhr.statusText || 'Upload failed'}`));
                            }
                        };
                        
                        xhr.onerror = () => reject(new Error('Network connection error during upload.'));
                        xhr.onabort = () => reject(new Error('Upload aborted.'));
                        
                        xhr.open('POST', '/upload-file?filename=' + encodeURIComponent(file.name));
                        xhr.setRequestHeader('Content-Type', 'application/octet-stream');
                        xhr.send(file);
                    });
                }

                async function uploadFiles(files) {
                    for (let file of files) {
                        try {
                            await uploadFile(file);
                            fetchGames();
                        } catch (err) {
                            statusBox.style.display = 'block';
                            statusBox.style.background = '#3b161c';
                            statusBox.style.color = '#f87171';
                            statusBox.style.border = '1px solid #ef4444';
                            statusBox.innerText = '✗ Error: ' + err.message;
                            break;
                        }
                    }
                }

                async function fetchGames() {
                    try {
                        let resp = await fetch('/api/games');
                        let games = await resp.json();
                        renderGames(games);
                    } catch (err) {
                        gamesContainer.innerHTML = '<div class="empty-state">Failed to load games: ' + err.message + '</div>';
                    }
                }

                function renderGames(games) {
                    if (!games || games.length === 0) {
                        gamesContainer.innerHTML = '<div class="empty-state">No ROM files detected on Apple TV storage.<br>Upload your games above!</div>';
                        return;
                    }

                    let html = '<table class="files-table"><thead><tr>' +
                        '<th>System</th><th>Game / Filename</th><th>Size</th><th>Action</th>' +
                        '</tr></thead><tbody>';

                    for (let g of games) {
                        let badgeClass = 'badge-other';
                        if (g.system === 'NES') badgeClass = 'badge-nes';
                        else if (g.system === 'SNES') badgeClass = 'badge-snes';
                        else if (g.system === 'N64') badgeClass = 'badge-n64';
                        else if (['GB/GBC', 'GBA', 'DS', 'Mega Drive'].includes(g.system)) badgeClass = 'badge-snes';

                        let internalInfo = '';
                        if (g.internalTitle && g.internalTitle !== g.cleanName) {
                            internalInfo = '<div class="internal-title">ROM Header Title: ' + escapeHtml(g.internalTitle) + '</div>';
                        }

                        html += '<tr>' +
                            '<td><span class="badge ' + badgeClass + '">' + escapeHtml(g.system) + '</span></td>' +
                            '<td><div class="file-name">' + escapeHtml(g.cleanName || g.filename) + '</div>' +
                                '<div class="internal-title" style="color:#64748b;">' + escapeHtml(g.filename) + '</div>' +
                                internalInfo +
                            '</td>' +
                            '<td><span class="file-size">' + escapeHtml(g.sizeFormatted) + '</span></td>' +
                            '<td><button class="btn-delete" onclick="deleteGame(\\'' + escapeJs(g.filename) + '\\')">🗑️ Delete</button></td>' +
                            '</tr>';
                    }

                    html += '</tbody></table>';
                    gamesContainer.innerHTML = html;
                }

                async function deleteGame(filename) {
                    if (!confirm('Are you sure you want to delete "' + filename + '" from Apple TV?')) return;
                    try {
                        let resp = await fetch('/api/delete?file=' + encodeURIComponent(filename), { method: 'POST' });
                        let res = await resp.json();
                        if (res.status === 'DELETED') {
                            showStatus('✓ Deleted ' + filename, 'success');
                            fetchGames();
                        } else {
                            showStatus('✗ Delete failed: ' + (res.error || 'Unknown error'), 'error');
                        }
                    } catch (e) {
                        showStatus('✗ Delete error: ' + e.message, 'error');
                    }
                }

                function escapeHtml(str) {
                    if (!str) return '';
                    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
                }
                function escapeJs(str) {
                    if (!str) return '';
                    return String(str).replace(/'/g, "\\\\'");
                }

                // Initial fetch
                fetchGames();
            </script>
        </body>
        </html>
        """
        
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        
        connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func sendJSONResponse(to connection: NWConnection, status: String, filename: String, size: Int) {
        let data = try! JSONSerialization.data(withJSONObject: ["status": status, "filename": filename, "size": size])
        let json = String(decoding: data, as: UTF8.self)
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(json.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r
        \(json)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func sendErrorResponse(to connection: NWConnection, message: String, statusCode: Int = 400) {
        let data = try! JSONSerialization.data(withJSONObject: ["status": "ERROR", "error": message])
        let json = String(decoding: data, as: UTF8.self)
        let statusLine = statusCode == 503 ? "503 Service Unavailable" : "400 Bad Request"
        let response = """
        HTTP/1.1 \(statusLine)\r
        Content-Type: application/json; charset=utf-8\r
        Content-Length: \(json.utf8.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r
        \(json)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func send404(to connection: NWConnection) {
        let notFound = "404 Not Found"
        let response = """
        HTTP/1.1 404 Not Found\r
        Content-Length: \(notFound.utf8.count)\r
        Connection: close\r
        \r
        \(notFound)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }
    
    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            var addr = ptr.pointee.ifa_addr.pointee
            
            // Check for IPv4 and non-loopback
            if addr.sa_family == UInt8(AF_INET) && (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(&addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let name = String(cString: hostname)
                    if !name.hasPrefix("127.") {
                        address = name
                        break
                    }
                }
            }
        }
        return address
    }
}
