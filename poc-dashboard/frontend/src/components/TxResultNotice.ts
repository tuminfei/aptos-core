import { notification } from 'antd';

export function showTxSuccess(action: string, txHash: string) {
  notification.success({
    message: `${action}成功`,
    description: `TX: ${txHash.slice(0, 16)}...`,
    duration: 5,
  });
}

export function showTxError(action: string, error: string) {
  notification.error({
    message: `${action}失败`,
    description: error,
    duration: 8,
  });
}
