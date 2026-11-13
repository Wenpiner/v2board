<?php

namespace App\Console\Commands;

use App\Models\User;
use App\Utils\Helper;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Redis;
use Illuminate\Support\Facades\Schema;

class V2boardDockerInit extends Command
{
    /**
     * The name and signature of the console command.
     *
     * @var string
     */
    protected $signature = 'v2board:docker-init {--wait=60 : 等待数据库和 Redis 就绪的最长秒数}';

    /**
     * The console command description.
     *
     * @var string
     */
    protected $description = 'Docker 容器启动时的非交互初始化（导入数据库、创建管理员）';

    /**
     * Execute the console command.
     *
     * @return mixed
     */
    public function handle()
    {
        $wait = (int)$this->option('wait');

        if (!$this->waitFor('MySQL', config('database.connections.mysql.host') . ':' . config('database.connections.mysql.port'), $wait, function () {
            DB::connection()->getPdo();
        })) {
            return 1;
        }
        if (!$this->waitFor('Redis', config('database.redis.default.host') . ':' . config('database.redis.default.port'), $wait, function () {
            Redis::connection()->ping();
        })) {
            return 1;
        }

        if (!Schema::hasTable('v2_user')) {
            if (!$this->importDatabase()) {
                return 1;
            }
        }

        if (User::where('is_admin', 1)->exists()) {
            $this->info('已存在管理员账号，跳过创建');
        } elseif (!$this->createAdmin()) {
            return 1;
        }

        $securePath = config('v2board.secure_path', config('v2board.frontend_admin_path', hash('crc32b', config('app.key'))));
        $this->info("管理面板地址：http(s)://你的站点/{$securePath}");
        return 0;
    }

    private function waitFor($name, $address, $timeout, callable $check)
    {
        $deadline = time() + $timeout;
        while (true) {
            try {
                $check();
                return true;
            } catch (\Throwable $e) {
                if (time() >= $deadline) {
                    $this->error("无法连接 {$name}（{$address}）：{$e->getMessage()}");
                    return false;
                }
                $this->line("等待 {$name}（{$address}）就绪...");
                sleep(2);
            }
        }
    }

    private function importDatabase()
    {
        $file = \File::get(base_path() . '/database/install.sql');
        if (!$file) {
            $this->error('数据库文件不存在');
            return false;
        }
        $sql = str_replace("\n", "", $file);
        $sql = preg_split("/;/", $sql);
        $this->info('正在导入数据库请稍等...');
        foreach ($sql as $item) {
            if (!trim($item)) continue;
            try {
                DB::select(DB::raw($item));
            } catch (\Exception $e) {
                $this->warn('SQL 执行失败：' . $e->getMessage());
            }
        }
        if (!Schema::hasTable('v2_user')) {
            $this->error('数据库导入失败：v2_user 表未创建');
            return false;
        }
        $this->info('数据库导入完成');
        return true;
    }

    private function createAdmin()
    {
        $email = env('ADMIN_EMAIL');
        if (!$email) {
            $this->error('未设置 ADMIN_EMAIL，无法创建管理员账号');
            return false;
        }
        if (!filter_var($email, FILTER_VALIDATE_EMAIL)) {
            $this->error("ADMIN_EMAIL 格式不正确：{$email}");
            return false;
        }
        $password = env('ADMIN_PASSWORD');
        $generated = !$password;
        if ($generated) {
            $password = Helper::guid(false);
        }
        if (strlen($password) < 8) {
            $this->error('ADMIN_PASSWORD 长度最小为8位字符');
            return false;
        }

        $user = User::where('email', $email)->first() ?? new User();
        $user->email = $email;
        $user->password = password_hash($password, PASSWORD_DEFAULT);
        $user->password_algo = null;
        $user->uuid = $user->uuid ?: Helper::guid(true);
        $user->token = $user->token ?: Helper::guid();
        $user->is_admin = 1;
        if (!$user->save()) {
            $this->error('管理员账号创建失败');
            return false;
        }

        $this->info('管理员账号已创建');
        $this->info("管理员邮箱：{$email}");
        $this->info($generated ? "管理员密码：{$password}" : '管理员密码：ADMIN_PASSWORD 中设置的密码');
        return true;
    }
}
