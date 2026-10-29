package rando_202412041742

func Render(path string) string {
return `class Step
  property can_continue : Bool = true
  property exception : Exception? = nil

  def initialize(&block : ->)
    @block = block
    run
  end

  def next(&block : ->)
    if can_continue
      self.class.new(&block)
    else
      self
    end
  end

  def run
    @block.call

    self
  rescue ex
    self.exception = ex
    self.can_continue = false

    return self
  end

  def rescue(&block : Exception -> _)
    self.rescue(Exception, &block)
  end

  def rescue(exception_type : Exception.class, &block : Exception -> _)
    if ex = self.exception && self.exception
      {{ ".is_a?(#{@def.args[0].restriction})" }}
      continue_flag = block.call(ex)
      self.can_continue = !!continue_flag
      raise ex if continue_flag == false
    end

    self
  end
end
`
}