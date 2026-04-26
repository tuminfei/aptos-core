from fastapi import HTTPException, Request
from fastapi.responses import JSONResponse


class AppError(HTTPException):
    def __init__(self, code: int, message: str, http_status: int = 400):
        self.code = code
        self.message = message
        super().__init__(status_code=http_status, detail=message)


class ParamError(AppError):
    def __init__(self, message: str = "参数校验失败"):
        super().__init__(40001, message, 400)


class AddressError(AppError):
    def __init__(self, message: str = "地址格式错误"):
        super().__init__(40002, message, 400)


class AmountError(AppError):
    def __init__(self, message: str = "金额不合法"):
        super().__init__(40003, message, 400)


class ValidatorNotFound(AppError):
    def __init__(self, message: str = "验证者不存在"):
        super().__init__(40401, message, 404)


class UserNotFound(AppError):
    def __init__(self, message: str = "用户无质押记录"):
        super().__init__(40402, message, 404)


class StateConflict(AppError):
    def __init__(self, message: str = "状态冲突"):
        super().__init__(40901, message, 409)


class ChainTxError(AppError):
    def __init__(self, message: str = "链上交易失败"):
        super().__init__(50001, message, 500)


class ChainUnreachable(AppError):
    def __init__(self, message: str = "链节点不可达"):
        super().__init__(50002, message, 500)


async def app_error_handler(request: Request, exc: AppError):
    return JSONResponse(
        status_code=exc.status_code,
        content={"code": exc.code, "message": exc.message},
    )
