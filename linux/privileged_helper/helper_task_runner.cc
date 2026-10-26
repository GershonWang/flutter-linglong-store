// 特权 helper 串行任务状态机实现。

#include "helper_task_runner.h"

namespace helper {

std::vector<std::string> HelperTaskRunner::buildArgv(const TaskSpec& spec) {
  std::vector<std::string> argv;
  argv.reserve(6);
  // 固定绝对路径，不经过 PATH 查找（§11 第 3 条）。
  argv.emplace_back("/usr/bin/ll-cli");
  if (spec.operation == HelperOperation::kUpdate) {
    argv.emplace_back("upgrade");
    argv.emplace_back("--json");
    argv.push_back(spec.appId);
    // 两类包操作使用同一可选清理控制，不接收任意外部选项。
    if (spec.noAutoPrune) argv.emplace_back("--no-auto-prune");
    return argv;
  }
  argv.emplace_back("install");
  argv.emplace_back("--json");
  argv.push_back(spec.version.empty() ? spec.appId
                                      : spec.appId + "/" + spec.version);
  if (spec.force) {
    argv.emplace_back("--force");
  }
  if (spec.noAutoPrune) argv.emplace_back("--no-auto-prune");
  return argv;
}

void HelperTaskRunner::begin(TaskSpec spec) {
  current_ = spec.requestId;
  spec_ = std::move(spec);
  cancelRequested_ = false;
}

CancelDecision HelperTaskRunner::decideCancel(
    const std::string& requestId) const {
  if (isIdle() || current_ != requestId) {
    return CancelDecision::kNotRunning;
  }
  return CancelDecision::kAccepted;
}

void HelperTaskRunner::finishCurrent() {
  current_.clear();
  spec_ = TaskSpec{};
  cancelRequested_ = false;
}

}  // namespace helper
