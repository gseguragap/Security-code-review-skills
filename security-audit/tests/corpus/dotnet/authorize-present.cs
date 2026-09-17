[Authorize(Policy = "CanModify")]
public class AdminController : ControllerBase {
    [HttpDelete("{id:int}")]
    public async Task<IActionResult> Delete(int id) => Ok(await _svc.DeleteAsync(id));
}
