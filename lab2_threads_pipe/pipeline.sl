// Lab 2: Pipeline CSV processing with software pipes
// Query 1: RIGHT JOIN Н_ТИПЫ_ВЕДОМОСТЕЙ and Н_ВЕДОМОСТИ
// Filter: НАИМЕНОВАНИЕ > 'Ведомость' (= ТВ_ИД >= 2) AND ЧЛВК_ИД > 153285
// Output: ТВ_ИД;ДАТА(YYYYMMDD)

// Runtime externals
void rtCreateThread(int func_addr);
void rtExitThread();
void rtSetupInterrupts();
void rtInitThreading();
int rtLoad(int addr);
void rtStore(int addr, int value);
int rtDeviceReadByte(int device_ctrl_addr);
void rtDeviceSendByte(int device_ctrl_addr, int byte_val);
void rtYield();

int swPipeCreate();
void swPipeWrite(int pipe_id, int value);
int swPipeRead(int pipe_id);
void swPipeClose(int pipe_id);

// === CSV Helpers ===

void skipField(int dev) {
    int ch = rtDeviceReadByte(dev);
    while (ch != 59 && ch != 10 && ch + 1 != 0 && ch != 13) {
        ch = rtDeviceReadByte(dev);
    }
}

void skipLine(int dev) {
    int ch = rtDeviceReadByte(dev);
    while (ch != 10 && ch + 1 != 0) {
        ch = rtDeviceReadByte(dev);
    }
}

int readIntField(int dev) {
    int result = 0;
    int ch = rtDeviceReadByte(dev);
    if (ch + 1 == 0) { return 0 - 1; }
    if (ch == 34) { ch = rtDeviceReadByte(dev); }
    while (ch != 59 && ch != 10 && ch + 1 != 0 && ch != 13) {
        if (ch >= 48 && ch <= 57) {
            result = result * 10 + ch - 48;
        }
        ch = rtDeviceReadByte(dev);
    }
    return result;
}

int readDateField(int dev) {
    int ch = rtDeviceReadByte(dev);
    if (ch + 1 == 0) { return 0 - 1; }
    if (ch == 59 || ch == 10 || ch == 13) { return 0; }
    int y = 0;
    int i = 0;
    while (i < 4 && ch >= 48 && ch <= 57) {
        y = y * 10 + ch - 48;
        ch = rtDeviceReadByte(dev);
        i = i + 1;
    }
    if (ch == 45) { ch = rtDeviceReadByte(dev); }
    int m = 0;
    i = 0;
    while (i < 2 && ch >= 48 && ch <= 57) {
        m = m * 10 + ch - 48;
        ch = rtDeviceReadByte(dev);
        i = i + 1;
    }
    if (ch == 45) { ch = rtDeviceReadByte(dev); }
    int d = 0;
    i = 0;
    while (i < 2 && ch >= 48 && ch <= 57) {
        d = d * 10 + ch - 48;
        ch = rtDeviceReadByte(dev);
        i = i + 1;
    }
    while (ch != 59 && ch != 10 && ch + 1 != 0 && ch != 13) {
        ch = rtDeviceReadByte(dev);
    }
    return y * 10000 + m * 100 + d;
}


void writeInt(int dev, int val) {
    if (val == 0) { rtDeviceSendByte(dev, 48); return; }
    // Find leading divisor
    int div = 1;
    int tmp = val;
    while (tmp >= 10) {
        div = div * 10;
        tmp = tmp / 10;
    }
    // Print digits from most significant
    while (div > 0) {
        int d = val / div;
        rtDeviceSendByte(dev, d + 48);
        val = val - d * div;
        div = div / 10;
    }
}


void parseVedmosti() {
    int dev = 180224;
    int pipe1 = rtLoad(159744);
    skipLine(dev);
    int eof = 0;
    while (eof == 0) {
        int id = readIntField(dev);
        if (id == 0) { eof = 1; }
        if (eof == 0) {
            int chelvk = readIntField(dev);
            int data = readDateField(dev);
            int tv_id = readIntField(dev);
            swPipeWrite(pipe1, chelvk);
            swPipeWrite(pipe1, data);
            swPipeWrite(pipe1, tv_id);
        }
    }
    swPipeClose(pipe1);
    rtExitThread();
}

void filterRows() {
    int pipe1 = rtLoad(159744);
    int pipe2 = rtLoad(159752);
    int chelvk = swPipeRead(pipe1);
    while (chelvk + 1 != 0) {
        int data = swPipeRead(pipe1);
        int tv_id = swPipeRead(pipe1);
        if (chelvk > 153285) {
            if (tv_id >= 2) {
                swPipeWrite(pipe2, tv_id);
                swPipeWrite(pipe2, data);
            }
        }
        chelvk = swPipeRead(pipe1);
    }
    swPipeClose(pipe2);
    rtExitThread();
}

void formatOutput() {
    int pipe2 = rtLoad(159752);
    int dev = 180224;
    int tv_id = swPipeRead(pipe2);
    while (tv_id + 1 != 0) {
        int data = swPipeRead(pipe2);
        writeInt(dev, tv_id);
        rtDeviceSendByte(dev, 59);
        writeInt(dev, data);
        rtDeviceSendByte(dev, 10);
        tv_id = swPipeRead(pipe2);
    }
    rtExitThread();
}

int main() {
    rtInitThreading();
    int p1 = swPipeCreate();
    int p2 = swPipeCreate();
    rtStore(159744, p1);
    rtStore(159752, p2);
    rtCreateThread(funcAddr(parseVedmosti));
    rtCreateThread(funcAddr(filterRows));
    rtCreateThread(funcAddr(formatOutput));
    rtSetupInterrupts();
    rtExitThread();
    return 0;
}
